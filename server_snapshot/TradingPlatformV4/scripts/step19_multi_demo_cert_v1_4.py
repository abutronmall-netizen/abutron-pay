from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
import sys

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as mt5
from sqlalchemy import select

from abutron.config import settings as core_settings
from abutron.models import (
    AccountState,
    BotTier,
    BrokerContext,
    Candle,
    Direction,
    FeatureVector,
    MarketBundle,
    MarketSnapshot,
    Thesis,
)
from abutron.profiles import profile_for, route_equity
from abutron.router import route_with_position_lock
from abutron.risk import RiskEngine
from abutron.capital import make_order_plan
from abutron.strategies import engine_for
from abutron.service import TradingService
from abutron.platform_db import session_scope, TradingAccount, TradeRecord
import abutron.worker as worker

from mt5_bridge.settings import settings as bridge_settings
from mt5_bridge.store import IdempotencyStore
import mt5_bridge.app as gateway


STEP19_BUILD_MARKER = "STEP19_MULTI_DEMO_CERT_V1_4"
STEP19_ACCEPTED_EVIDENCE_BUILD_MARKERS = {
    "STEP19_EQUITY_ROUTER_BOT_LIFECYCLE_V1",
    "STEP19_MULTI_DEMO_CERT_V1_3",
    "STEP19_MULTI_DEMO_CERT_V1_4",
}
LEDGER = ROOT / "logs" / "step19_tier_evidence.json"


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def raw_symbol(symbol: str) -> str:
    return gateway.raw_symbol(symbol)


def executable_tiers():
    return (
        BotTier.FLIPPER,
        BotTier.SCALPER,
        BotTier.MASTER,
    )


EXPECTED = {
    BotTier.FLIPPER: {
        "equity": 1000.0,
        "name": "flipper-v4-adaptive-directional",
        "primary_tf": "M1",
        "context_tfs": ["M5", "M15"],
    },
    BotTier.SCALPER: {
        "equity": 4000.0,
        "name": "scalper-v4-precision-sniper",
        "primary_tf": "M1",
        "context_tfs": ["M5", "M15"],
    },
    BotTier.MASTER: {
        "equity": 7500.0,
        "name": "master-v4-mtf-capital",
        "primary_tf": "M15",
        "context_tfs": ["H1", "H4"],
    },
}


def make_market(symbol: str, timeframe: str, spread: float = 1.0) -> MarketBundle:
    now = int(time.time())
    candle = Candle(
        ts=now,
        open=100.0,
        high=101.0,
        low=99.0,
        close=100.5,
        volume=1.0,
    )
    return MarketBundle(
        primary=MarketSnapshot(
            symbol=symbol,
            timeframe=timeframe,
            candles=[candle],
            spread_points=float(spread),
            received_ts=now,
        ),
        contexts={},
    )


def make_features(atr: float) -> FeatureVector:
    return FeatureVector(
        trend=1.0,
        htf_trend=1.0,
        momentum=1.0,
        rsi=0.0,
        structure=1.0,
        liquidity=1.0,
        fvg=1.0,
        order_block=1.0,
        displacement=1.0,
        premium_discount=0.0,
        volatility_quality=1.0,
        regime_score=1.0,
        regime="CERTIFICATION",
        atr=float(atr),
        metadata={
            "synthetic": True,
            "purpose": "STEP19_ROUTER_BOT_CONTRACT",
        },
    )


def make_thesis(symbol: str, direction: Direction = Direction.BUY) -> Thesis:
    return Thesis(
        symbol=symbol,
        direction=direction,
        confidence=99.0,
        score=1.0 if direction == Direction.BUY else -1.0,
        valid=True,
        reason="STEP19_CERTIFICATION_NOT_A_MARKET_SIGNAL",
        regime="CERTIFICATION",
        evidence={
            "synthetic": True,
            "purpose": "STEP19_ROUTER_BOT_CONTRACT",
        },
    )


def deterministic_all_tier_contracts() -> None:
    broker = BrokerContext(
        symbol="XAUUSD",
        bid=100.0,
        ask=100.1,
        point=0.01,
        tick_size=0.01,
        tick_value=1.0,
        volume_min=0.01,
        volume_max=100.0,
        volume_step=0.01,
        spread_points=10.0,
        positions_on_symbol=0,
    )

    for tier in executable_tiers():
        cfg = EXPECTED[tier]
        equity = float(cfg["equity"])

        route = route_with_position_lock(
            equity=equity,
            current_tier=None,
            open_positions=0,
        )
        require(route.selected == tier, f"{tier.value} route mismatch.")
        require(route.requested == tier, f"{tier.value} requested route mismatch.")
        require(route.locked is False, f"{tier.value} unexpectedly locked.")

        profile = profile_for(tier)
        require(profile.tier == tier, f"{tier.value} profile tier mismatch.")
        require(profile.name == cfg["name"], f"{tier.value} profile name mismatch.")
        require(profile.primary_tf == cfg["primary_tf"], f"{tier.value} primary TF mismatch.")
        require(list(profile.context_tfs) == cfg["context_tfs"], f"{tier.value} context TF mismatch.")

        thesis = make_thesis("XAUUSD", Direction.BUY)
        policy = engine_for(tier).policy(profile, thesis)
        require(policy.tier == tier, f"{tier.value} strategy tier mismatch.")
        require(policy.name == profile.name, f"{tier.value} strategy name mismatch.")
        require(policy.primary_tf == profile.primary_tf, f"{tier.value} strategy primary TF mismatch.")
        require(list(policy.context_tfs) == list(profile.context_tfs), f"{tier.value} strategy context mismatch.")

        account = AccountState(
            equity=equity,
            balance=equity,
            daily_pnl=0.0,
            open_risk=0.0,
            license_active=True,
            positions_total=0,
            login="",
            server="",
            currency="USD",
        )

        market = make_market("XAUUSD", profile.primary_tf, broker.spread_points)

        risk = RiskEngine().evaluate(
            thesis=thesis,
            account=account,
            broker=broker,
            market=market,
            tier=tier,
        )
        require(risk.approved, f"{tier.value} risk rejected: {risk.reason}")

        risk_target = min(
            account.equity * (profile.risk_pct / 100.0),
            risk.max_risk_amount,
        )
        denom = (
            profile.sl_atr
            * broker.tick_value
            * broker.volume_min
        )
        require(risk_target > 0, f"{tier.value} invalid risk target.")
        require(denom > 0, f"{tier.value} invalid capital denominator.")

        cert_atr = (
            0.75
            * risk_target
            * broker.tick_size
            / denom
        )

        features = make_features(cert_atr)

        plan = make_order_plan(
            thesis=thesis,
            features=features,
            account=account,
            broker=broker,
            risk=risk,
            bar_ts=market.primary.candles[-1].ts,
            tier=tier,
        )

        require(plan is not None, f"{tier.value} capital returned no plan.")
        require(plan.tier == tier, f"{tier.value} plan tier mismatch.")
        require(plan.strategy_profile == profile.name, f"{tier.value} plan strategy profile mismatch.")
        require(plan.risk_amount <= risk.max_risk_amount + 1e-9, f"{tier.value} plan exceeded risk authorization.")
        require(plan.volume >= broker.volume_min - 1e-12, f"{tier.value} volume below minimum.")
        require(plan.volume <= broker.volume_max + 1e-12, f"{tier.value} volume above maximum.")

        emit(f"DETERMINISTIC_{tier.value}_ROUTE", "PASS")
        emit(f"DETERMINISTIC_{tier.value}_PROFILE", "PASS")
        emit(f"DETERMINISTIC_{tier.value}_STRATEGY", "PASS")
        emit(f"DETERMINISTIC_{tier.value}_RISK", "PASS")
        emit(f"DETERMINISTIC_{tier.value}_CAPITAL", "PASS")

    # Sticky lock: requested tier may change while open, selected tier must not.
    lock_cases = (
        (BotTier.FLIPPER, 7500.0),
        (BotTier.SCALPER, 7500.0),
        (BotTier.MASTER, 1000.0),
    )

    for current, new_equity in lock_cases:
        locked = route_with_position_lock(
            equity=new_equity,
            current_tier=current,
            open_positions=1,
        )
        require(locked.selected == current, f"Sticky lock failed for {current.value}.")
        require(locked.locked is True, f"Sticky lock flag failed for {current.value}.")

    emit("DETERMINISTIC_ALL_TIER_CONTRACTS", "PASS")
    emit("DETERMINISTIC_STICKY_TIER_LOCK", "PASS")


class NoopDecisionStore:
    def add(self, *args, **kwargs):
        return None


async def live_stack_route_attestation(expected_tier: BotTier):
    svc = TradingService()
    svc.store = NoopDecisionStore()

    result = await svc.evaluate_live(
        "XAUUSD",
        execute=False,
    )

    require(
        result.route.selected == expected_tier,
        "Live TradingService route disagrees with direct equity route.",
    )
    require(result.strategy is not None, "Live TradingService produced no strategy policy.")
    require(result.strategy.tier == expected_tier, "Live strategy tier mismatch.")

    profile = profile_for(expected_tier)
    require(result.strategy.name == profile.name, "Live strategy name mismatch.")
    require(result.strategy.primary_tf == profile.primary_tf, "Live primary timeframe mismatch.")
    require(
        list(result.strategy.context_tfs) == list(profile.context_tfs),
        "Live context timeframes mismatch.",
    )
    require(result.execution is None, "Read-only live route attestation unexpectedly executed.")

    emit("LIVE_STACK_ROUTE_ATTESTATION", "PASS")
    emit("LIVE_STACK_STRATEGY_ATTESTATION", "PASS")
    emit("LIVE_STACK_EXECUTION", "NONE")

    return result


def broker_context(symbol: str) -> BrokerContext:
    rs = raw_symbol(symbol)
    require(mt5.symbol_select(rs, True), f"Could not select broker symbol: {rs}")

    info = mt5.symbol_info(rs)
    tick = mt5.symbol_info_tick(rs)
    require(info is not None, "symbol_info unavailable.")
    require(tick is not None, "symbol_info_tick unavailable.")

    point = float(getattr(info, "point", 0.0) or 0.0)
    spread = (
        (float(tick.ask) - float(tick.bid)) / point
        if point > 0
        else float(getattr(info, "spread", 0.0) or 0.0)
    )

    positions = mt5.positions_get(symbol=rs)
    require(positions is not None, f"positions_get({rs}) failed: {mt5.last_error()}")

    return BrokerContext(
        symbol=symbol,
        bid=float(tick.bid),
        ask=float(tick.ask),
        point=point,
        tick_size=float(getattr(info, "trade_tick_size", 0.0) or point),
        tick_value=float(getattr(info, "trade_tick_value", 0.0) or 0.0),
        volume_min=float(getattr(info, "volume_min", 0.0) or 0.0),
        volume_max=float(getattr(info, "volume_max", 0.0) or 0.0),
        volume_step=float(getattr(info, "volume_step", 0.0) or 0.0),
        spread_points=float(spread),
        positions_on_symbol=len(positions),
    )


def symbol_positions(symbol: str):
    rows = mt5.positions_get(symbol=symbol)
    if rows is None:
        raise RuntimeError(f"positions_get({symbol}) failed: {mt5.last_error()}")
    return list(rows)


def symbol_orders(symbol: str):
    rows = mt5.orders_get(symbol=symbol)
    if rows is None:
        raise RuntimeError(f"orders_get({symbol}) failed: {mt5.last_error()}")
    return list(rows)


def all_abutron_positions(magic: int):
    rows = mt5.positions_get()
    if rows is None:
        raise RuntimeError(f"positions_get failed: {mt5.last_error()}")
    return [
        p for p in rows
        if int(getattr(p, "magic", 0) or 0) == int(magic)
        or str(getattr(p, "comment", "") or "").upper().startswith("ABUTRON")
    ]


def wait_position(symbol: str, magic: int, seconds: int = 20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = symbol_positions(symbol)
        owned = [
            p for p in rows
            if int(getattr(p, "magic", 0) or 0) == int(magic)
            or str(getattr(p, "comment", "") or "").upper().startswith("ABUTRON")
        ]
        if len(owned) == 1:
            return owned[0]
        if len(owned) > 1:
            raise RuntimeError("Multiple Abutron positions appeared during Step19.")
        time.sleep(0.5)
    return None


def wait_absent(ticket: int, seconds: int = 20) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = mt5.positions_get(ticket=int(ticket))
        if rows is None:
            raise RuntimeError(f"positions_get(ticket) failed: {mt5.last_error()}")
        if len(rows) == 0:
            return True
        time.sleep(0.5)
    return False


def wait_sl_change(ticket: int, old_sl: float, is_buy: bool, seconds: int = 20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = mt5.positions_get(ticket=int(ticket))
        if rows is None:
            raise RuntimeError(f"positions_get(ticket) failed: {mt5.last_error()}")
        if len(rows) != 1:
            return None
        pos = rows[0]
        sl = float(pos.sl)
        if (is_buy and sl > old_sl + 1e-12) or (
            (not is_buy) and sl < old_sl - 1e-12
        ):
            return pos
        time.sleep(0.5)
    return None


def deal_dict(d) -> dict:
    return {
        "ticket": int(getattr(d, "ticket", 0) or 0),
        "order": int(getattr(d, "order", 0) or 0),
        "position_id": int(getattr(d, "position_id", 0) or 0),
        "time": int(getattr(d, "time", 0) or 0),
        "time_msc": int(getattr(d, "time_msc", 0) or 0),
        "type": int(getattr(d, "type", 0) or 0),
        "entry": int(getattr(d, "entry", 0) or 0),
        "magic": int(getattr(d, "magic", 0) or 0),
        "volume": float(getattr(d, "volume", 0.0) or 0.0),
        "price": float(getattr(d, "price", 0.0) or 0.0),
        "profit": float(getattr(d, "profit", 0.0) or 0.0),
        "commission": float(getattr(d, "commission", 0.0) or 0.0),
        "swap": float(getattr(d, "swap", 0.0) or 0.0),
        "symbol": str(getattr(d, "symbol", "") or ""),
        "comment": str(getattr(d, "comment", "") or ""),
    }


def history_for_position(ticket: int):
    now = datetime.now(timezone.utc)
    rows = mt5.history_deals_get(
        now - timedelta(days=7),
        now + timedelta(days=1),
    )
    if rows is None:
        raise RuntimeError(f"history_deals_get failed: {mt5.last_error()}")
    return [
        deal_dict(d)
        for d in rows
        if int(getattr(d, "position_id", 0) or 0) == int(ticket)
    ]


def wait_history(ticket: int, minimum: int = 2, seconds: int = 20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = history_for_position(ticket)
        if len(rows) >= minimum:
            return rows
        time.sleep(0.5)
    return history_for_position(ticket)


def exact_platform_account(login: str, server: str):
    with session_scope() as s:
        account = worker._find_account(
            s,
            str(login),
            str(server),
        )
        return {
            "id": int(account.id),
            "current_tier": str(account.current_tier or ""),
        }


def restore_platform_current_tier(
    login: str,
    server: str,
    previous_tier: str,
) -> None:
    with session_scope() as s:
        account = worker._find_account(
            s,
            str(login),
            str(server),
        )
        account.current_tier = str(previous_tier or "")


def fetch_trade_record(signal_id: str):
    with session_scope() as s:
        row = s.scalar(
            select(TradeRecord)
            .where(TradeRecord.signal_id == signal_id)
            .order_by(TradeRecord.id.asc())
        )
        if row is None:
            return None

        payload = {}
        try:
            payload = json.loads(row.payload or "{}")
        except Exception:
            payload = {}

        return {
            "id": int(row.id),
            "account_id": int(row.account_id) if row.account_id is not None else None,
            "symbol": str(row.symbol or ""),
            "side": str(row.side or ""),
            "tier": str(row.tier or ""),
            "state": str(row.state or ""),
            "ticket": str(row.ticket or ""),
            "signal_id": str(row.signal_id or ""),
            "opened_ts": row.opened_ts,
            "closed_ts": row.closed_ts,
            "payload": payload,
        }


class CertResult:
    def __init__(
        self,
        *,
        symbol: str,
        tier: BotTier,
        strategy_name: str,
        plan,
        execution: dict,
    ):
        self.symbol = symbol
        self.plan = plan
        self.execution = execution
        self.route = SimpleNamespace(
            selected=tier,
            locked=False,
        )
        self.strategy = SimpleNamespace(
            name=strategy_name,
            tier=tier,
        )

    def model_dump(self, mode="json"):
        return {
            "symbol": self.symbol,
            "route": {
                "selected": self.route.selected.value,
                "locked": self.route.locked,
            },
            "strategy": {
                "name": self.strategy.name,
                "tier": self.strategy.tier.value,
            },
            "plan": self.plan.model_dump(mode="json"),
            "execution": dict(self.execution),
            "certification": {
                "step": 19,
                "market_signal_used": False,
            },
        }


def emergency_close(ticket: int, magic: int) -> bool:
    rows = mt5.positions_get(ticket=int(ticket))
    if not rows:
        return True
    if len(rows) != 1:
        return False

    pos = rows[0]
    owned = (
        int(getattr(pos, "magic", 0) or 0) == int(magic)
        or str(getattr(pos, "comment", "") or "").upper().startswith("ABUTRON")
    )
    if not owned:
        return False

    fills = [
        ("IOC", mt5.ORDER_FILLING_IOC),
        ("FOK", mt5.ORDER_FILLING_FOK),
        ("RETURN", mt5.ORDER_FILLING_RETURN),
    ]

    for _ in range(4):
        rows = mt5.positions_get(ticket=int(ticket))
        if not rows:
            return True

        pos = rows[0]
        tick = mt5.symbol_info_tick(pos.symbol)
        if tick is None:
            time.sleep(1)
            continue

        is_buy = int(pos.type) == int(mt5.POSITION_TYPE_BUY)
        selected = None

        for fill_name, fill_value in fills:
            req = {
                "action": mt5.TRADE_ACTION_DEAL,
                "position": int(pos.ticket),
                "symbol": pos.symbol,
                "volume": float(pos.volume),
                "type": mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
                "price": float(tick.bid if is_buy else tick.ask),
                "deviation": max(int(bridge_settings.deviation_points), 50),
                "magic": int(magic),
                "comment": "ABUTRON S19 EMERG",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": int(fill_value),
            }
            check = mt5.order_check(req)
            if check is not None and int(getattr(check, "retcode", -1)) == 0:
                selected = (fill_name, req)
                break

        if selected is None:
            return False

        fill_name, req = selected
        emit("STEP19_EMERGENCY_FILLING", fill_name)

        result = mt5.order_send(req)
        if result is not None and int(result.retcode) in (
            int(mt5.TRADE_RETCODE_DONE),
            int(mt5.TRADE_RETCODE_DONE_PARTIAL),
        ):
            if wait_absent(ticket, 15):
                return True

        time.sleep(1)

    return wait_absent(ticket, 2)


def read_ledger() -> dict:
    if not LEDGER.exists():
        return {}
    try:
        value = json.loads(LEDGER.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def write_ledger(ledger: dict) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    tmp = LEDGER.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(ledger, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    tmp.replace(LEDGER)


def ledger_status(ledger: dict) -> bool:
    all_pass = True

    def valid_entry(tier: BotTier) -> bool:
        entry = ledger.get(tier.value)
        if not isinstance(entry, dict):
            return False

        expected_profile = EXPECTED[tier]["name"]
        expected_server = str(bridge_settings.expected_server or "").strip()

        try:
            ticket = int(entry.get("position_ticket", 0) or 0)
            certified_ts = int(entry.get("certified_ts", 0) or 0)
        except Exception:
            return False

        signal_id = str(entry.get("signal_id", "") or "")
        build_marker = str(entry.get("build_marker", "") or "")
        server = str(entry.get("server", "") or "").strip()

        return (
            entry.get("status") == "PASS"
            and build_marker in STEP19_ACCEPTED_EVIDENCE_BUILD_MARKERS
            and str(entry.get("symbol", "")).upper() == "XAUUSD"
            and str(entry.get("strategy_profile", "")) == expected_profile
            and bool(expected_server)
            and server.casefold() == expected_server.casefold()
            and ticket > 0
            and certified_ts > 0
            and signal_id.startswith("STEP19-")
        )

    for tier in executable_tiers():
        ok = valid_entry(tier)
        emit(f"STEP19_{tier.value}_BROKER_LIFECYCLE", "PASS" if ok else "PENDING")
        all_pass = all_pass and ok

    count = sum(
        1
        for tier in executable_tiers()
        if valid_entry(tier)
    )
    emit("STEP19_CERTIFIED_TIER_COUNT", count)
    emit("STEP19_ALL_THREE_BOTS_CERTIFIED", all_pass)
    emit("STEP19_LEDGER_COMPATIBILITY_CHECK", "PASS")
    return all_pass


def actual_account_state(valid_auth: str) -> AccountState:
    payload = gateway.account(authorization=valid_auth)
    account = AccountState(**payload)

    if core_settings.enforce_platform_license:
        account.license_active = TradingService._platform_license_for_login(
            account.login
        )

    require(account.license_active is True, "Platform license is not active for connected DEMO account.")
    return account


def preflight(require_tier: str) -> tuple[AccountState, BotTier, str, BrokerContext]:
    deterministic_all_tier_contracts()

    terminal = mt5.terminal_info()
    account_info = mt5.account_info()
    require(terminal is not None, "MT5 terminal_info unavailable.")
    require(account_info is not None, "MT5 account_info unavailable.")
    require(bool(terminal.connected), "MT5 terminal is disconnected.")
    require(bool(terminal.trade_allowed), "MT5 terminal Algo Trading permission is OFF.")

    gateway._require_demo_if_configured()
    emit("DEMO_ACCOUNT_IDENTITY", "PASS")
    emit("ACCOUNT_LOGIN_PRINTED", False)
    emit("ACCOUNT_EQUITY_PRINTED", False)

    valid_auth = f"Bearer {bridge_settings.api_token}"
    gateway.auth(valid_auth)

    account = actual_account_state(valid_auth)
    selected = route_equity(account.equity)

    require(
        selected in executable_tiers(),
        f"ACTUAL_EQUITY_ROUTE_NOT_EXECUTABLE:{selected.value}",
    )

    if require_tier != "ANY":
        require(
            selected.value == require_tier,
            f"ACTUAL_SELECTED_TIER_{selected.value}_DOES_NOT_MATCH_REQUIRED_{require_tier}",
        )

    emit("ACTUAL_EQUITY_ROUTE", "PASS")
    emit("ACTUAL_SELECTED_TIER", selected.value)

    profile = profile_for(selected)
    emit("ACTUAL_STRATEGY_PROFILE", profile.name)

    rs = raw_symbol("XAUUSD")
    require(mt5.symbol_select(rs, True), f"Could not select broker symbol: {rs}")

    require(len(symbol_positions(rs)) == 0, "Step19 requires zero existing XAUUSD positions.")
    require(len(symbol_orders(rs)) == 0, "Step19 requires zero XAUUSD pending orders.")
    require(len(all_abutron_positions(int(bridge_settings.magic))) == 0, "Step19 requires zero Abutron positions.")

    emit("ZERO_SYMBOL_POSITION_BASELINE", "PASS")
    emit("ZERO_SYMBOL_PENDING_ORDER_BASELINE", "PASS")
    emit("ZERO_ABUTRON_POSITION_BASELINE", "PASS")

    platform_account = exact_platform_account(
        account.login,
        account.server,
    )
    require(platform_account["id"] > 0, "Exact platform TradingAccount binding failed.")
    emit("EXACT_PLATFORM_ACCOUNT_BINDING", "PASS")

    live_result = asyncio.run(
        live_stack_route_attestation(selected)
    )
    require(
        live_result.strategy.name == profile.name,
        "Live stack strategy profile mismatch.",
    )

    broker = broker_context("XAUUSD")

    emit("STEP19_PREFLIGHT", "PASS")
    return account, selected, rs, broker


def demo_lifecycle(
    *,
    direction: Direction,
    require_tier: str,
) -> int:
    original_store = gateway.store
    original_db = str(bridge_settings.idempotency_db)
    original_live = bool(bridge_settings.live_trading)
    original_management = bool(bridge_settings.management_enabled)
    original_be_enabled = bool(bridge_settings.break_even_enabled)
    original_trailing_enabled = bool(bridge_settings.trailing_enabled)
    original_be_r = float(bridge_settings.break_even_r)
    original_trail_start = float(bridge_settings.trail_start_r)
    original_trail_distance = float(bridge_settings.trail_distance_r)

    temp_dir = Path(
        tempfile.mkdtemp(
            prefix="abutron-step19-",
            dir=str(ROOT / "logs"),
        )
    )
    temp_db = temp_dir / "step19_idempotency.sqlite3"

    cert_ticket = None
    cert_key = f"STEP19-{int(time.time())}-{uuid.uuid4().hex[:12]}"
    opened = False
    closed_normally = False
    persisted = False
    emergency_used = False
    emergency_ok = None
    certification_error = None
    account = None
    selected = None
    rs = None
    original_platform_tier = None

    try:
        account, selected, rs, broker = preflight(require_tier)
        profile = profile_for(selected)

        original_platform_tier = exact_platform_account(
            account.login,
            account.server,
        )["current_tier"]

        valid_auth = f"Bearer {bridge_settings.api_token}"

        bridge_settings.idempotency_db = str(temp_db)
        gateway.settings.idempotency_db = str(temp_db)
        cert_store = IdempotencyStore()
        gateway.store = cert_store

        market = make_market(
            "XAUUSD",
            profile.primary_tf,
            broker.spread_points,
        )
        thesis = make_thesis("XAUUSD", direction)

        risk = RiskEngine().evaluate(
            thesis=thesis,
            account=account,
            broker=broker,
            market=market,
            tier=selected,
        )
        require(risk.approved, f"RiskEngine rejected Step19 DEMO lifecycle: {risk.reason}")
        emit("ACTUAL_TIER_RISK_ENGINE", "PASS")

        risk_target = min(
            account.equity * (profile.risk_pct / 100.0),
            risk.max_risk_amount,
        )
        denom = (
            profile.sl_atr
            * broker.tick_value
            * broker.volume_min
        )
        require(risk_target > 0, "Actual-tier risk target is not positive.")
        require(broker.tick_size > 0, "Broker tick_size is invalid.")
        require(denom > 0, "Actual-tier capital denominator is invalid.")

        cert_atr = (
            0.75
            * risk_target
            * broker.tick_size
            / denom
        )
        features = make_features(cert_atr)

        plan = make_order_plan(
            thesis=thesis,
            features=features,
            account=account,
            broker=broker,
            risk=risk,
            bar_ts=market.primary.candles[-1].ts,
            tier=selected,
        )
        require(plan is not None, "Capital Engine returned no actual-tier Step19 plan.")

        plan = plan.model_copy(
            update={
                "idempotency_key": cert_key,
                "thesis_reason": "STEP19_CONTROLLED_DEMO_ROUTER_CERT_NOT_A_MARKET_SIGNAL",
            }
        )

        require(plan.tier == selected, "Capital plan tier != actual equity route.")
        require(plan.strategy_profile == profile.name, "Capital strategy profile != selected tier profile.")
        require(plan.risk_amount <= risk.max_risk_amount + 1e-9, "Capital plan exceeds authorized risk.")
        emit("ACTUAL_TIER_CAPITAL_ENGINE", "PASS")
        emit("PLAN_TIER_PROFILE_ALIGNMENT", "PASS")

        rs2, desired_buy, request, info = gateway._build_order_request(plan)
        require(rs2 == rs, "Resolved broker symbol changed.")
        require(abs(float(plan.volume) - float(info.volume_min)) < 1e-12, "Step19 plan is not broker minimum volume.")
        require(float(request["volume"]) == float(info.volume_min), "Step19 request is not broker minimum volume.")
        require(int(request["magic"]) == int(bridge_settings.magic), "Step19 magic mismatch.")

        expected_comment = f"ABUTRON {selected.value}".upper()
        actual_comment = str(request["comment"]).upper()
        require(actual_comment.startswith(expected_comment), "Order comment does not attest selected tier.")

        emit("BROKER_TIER_COMMENT_PRECHECK", "PASS")
        emit("BROKER_MINIMUM_VOLUME_ONLY", "PASS")

        check = mt5.order_check(request)
        require(check is not None, f"MT5 order_check failed: {mt5.last_error()}")
        require(int(getattr(check, "retcode", -1)) == 0, "Broker order_check rejected Step19 request.")
        emit("BROKER_ORDER_CHECK", "PASS")

        # Process-local execution window only. Production Bridge/.env remains OFF.
        gateway.settings.live_trading = True
        bridge_settings.live_trading = True

        result = gateway.order(
            plan,
            authorization=valid_auth,
        )

        require(result.get("accepted") is True, f"Step19 DEMO open failed: {result}")
        require(
            int(result.get("retcode", -1)) == int(mt5.TRADE_RETCODE_DONE),
            "Step19 open retcode is not DONE.",
        )
        opened = True
        emit("REAL_DEMO_OPEN", "PASS")

        position = wait_position(
            rs,
            int(bridge_settings.magic),
            20,
        )
        require(position is not None, "Step19 broker position not found.")

        cert_ticket = int(position.ticket)
        returned_ticket = int(result.get("position_ticket", 0) or 0)
        require(returned_ticket == cert_ticket, "Gateway/broker position ticket mismatch.")

        broker_comment = str(getattr(position, "comment", "") or "").upper()
        require(
            broker_comment.startswith("ABUTRON")
            and selected.value in broker_comment,
            "Broker position comment does not preserve selected bot tier.",
        )

        emit("BROKER_POSITION_TIER_ATTESTATION", "PASS")
        emit("POSITION_TICKET_RECONCILIATION", "PASS")

        cert_result = CertResult(
            symbol="XAUUSD",
            tier=selected,
            strategy_name=profile.name,
            plan=plan,
            execution=result,
        )

        record_id = worker.persist_execution(
            cert_result,
            account.login,
            account.server,
        )
        require(record_id is not None, "Production worker persist_execution returned no record.")
        persisted = True

        db_row = fetch_trade_record(cert_key)
        require(db_row is not None, "Step19 TradeRecord not found after persist_execution.")
        require(db_row["tier"] == selected.value, "Database tier != selected equity route.")
        require(db_row["ticket"] == str(cert_ticket), "Database ticket != broker position ticket.")
        require(db_row["state"] in ("EXECUTED", "OPENED"), "Unexpected database state after execution.")
        emit("DATABASE_EXECUTION_TIER_PERSISTENCE", "PASS")

        account_binding = exact_platform_account(
            account.login,
            account.server,
        )
        require(
            account_binding["current_tier"] == selected.value,
            "TradingAccount.current_tier not updated to selected route.",
        )
        emit("DATABASE_CURRENT_TIER_ASSIGNMENT", "PASS")

        # Use hardened production management path on the actual selected-tier position.
        info = mt5.symbol_info(rs)
        tick = mt5.symbol_info_tick(rs)
        require(info is not None and tick is not None, "Broker market info unavailable before manage.")

        point = float(getattr(info, "point", 0.0) or 0.0)
        tick_size = float(
            getattr(info, "trade_tick_size", 0.0)
            or point
            or 0.0
        )
        require(tick_size > 0, "Invalid broker tick size during management.")

        safe_distance = (
            max(
                int(getattr(info, "trade_stops_level", 0) or 0),
                int(getattr(info, "trade_freeze_level", 0) or 0),
                0,
            )
            * point
            + tick_size
        )
        cert_initial_r = max(
            safe_distance * 2.0,
            tick_size * 20.0,
        )
        cert_store.put_position(
            cert_ticket,
            cert_initial_r,
            selected.value,
            cert_key,
        )

        before_rows = mt5.positions_get(ticket=cert_ticket) or []
        require(len(before_rows) == 1, "Position disappeared before Step19 management.")
        before = before_rows[0]
        old_sl = float(before.sl)
        is_buy = int(before.type) == int(mt5.POSITION_TYPE_BUY)

        gateway.settings.break_even_enabled = False
        bridge_settings.break_even_enabled = False
        gateway.settings.trailing_enabled = True
        bridge_settings.trailing_enabled = True
        gateway.settings.trail_start_r = -1000000.0
        bridge_settings.trail_start_r = -1000000.0
        gateway.settings.trail_distance_r = 1.0
        bridge_settings.trail_distance_r = 1.0
        gateway.settings.management_enabled = True
        bridge_settings.management_enabled = True

        managed = gateway.manage(
            authorization=valid_auth
        )
        actions = [
            a for a in managed.get("actions", [])
            if int(a.get("ticket", 0) or 0) == cert_ticket
        ]
        require(len(actions) == 1, f"Expected one actual-tier management action; got {actions}")
        require(actions[0].get("ok") is True, f"Actual-tier broker management failed: {actions[0]}")

        changed = wait_sl_change(
            cert_ticket,
            old_sl,
            is_buy,
            20,
        )
        require(changed is not None, "Actual-tier broker SL did not improve.")

        actual_sl = float(changed.sl)
        if is_buy:
            require(actual_sl > old_sl + 1e-12, "Step19 BUY SL worsened or did not improve.")
        else:
            require(actual_sl < old_sl - 1e-12, "Step19 SELL SL worsened or did not improve.")

        emit("ACTUAL_TIER_REAL_MANAGEMENT", "PASS")
        emit("ACTUAL_TIER_NO_WORSENING_SL", "PASS")

        close_result = gateway.close(
            cert_ticket,
            authorization=valid_auth,
        )
        require(close_result.get("closed") is True, f"Step19 normal close failed: {close_result}")
        require(
            int(close_result.get("retcode", -1)) == int(mt5.TRADE_RETCODE_DONE),
            "Step19 close retcode is not DONE.",
        )
        require(wait_absent(cert_ticket, 20), "Step19 position remains after normal close.")
        closed_normally = True
        emit("ACTUAL_TIER_NORMAL_CLOSE", "PASS")

        deals = wait_history(
            cert_ticket,
            minimum=2,
            seconds=20,
        )
        require(len(deals) >= 2, "Step19 broker history did not expose open+close deals.")

        worker.sync_deals(
            deals,
            account.login,
            account.server,
        )
        worker.sync_deals(
            deals,
            account.login,
            account.server,
        )
        emit("DATABASE_RECONCILIATION_IDEMPOTENT", "PASS")

        final_row = fetch_trade_record(cert_key)
        require(final_row is not None, "Step19 TradeRecord disappeared.")
        require(final_row["tier"] == selected.value, "Closed TradeRecord tier changed.")
        require(final_row["ticket"] == str(cert_ticket), "Closed TradeRecord ticket mismatch.")
        require(final_row["state"] == "CLOSED", f"Step19 TradeRecord did not reach CLOSED: {final_row['state']}")
        require(final_row["closed_ts"] is not None, "Step19 TradeRecord has no closed_ts.")

        reconciliation = final_row["payload"].get("reconciliation")
        require(isinstance(reconciliation, dict), "Database reconciliation payload missing.")
        require(int(reconciliation.get("deal_count", 0) or 0) >= 2, "Database reconciliation deal_count < 2.")

        emit("DATABASE_CLOSED_TIER_RECONCILIATION", "PASS")
        emit("BROKER_DATABASE_POSITION_AGREEMENT", "PASS")

        require(len(symbol_positions(rs)) == 0, "Residual XAUUSD exposure remains.")
        require(len(all_abutron_positions(int(bridge_settings.magic))) == 0, "Residual Abutron exposure remains.")
        emit("ZERO_RESIDUAL_EXPOSURE", "PASS")

        require(cert_store.get_position(cert_ticket) is None, "Temporary position metadata not removed.")
        emit("POSITION_METADATA_CLEANUP", "PASS")

        # Record actual broker certification for this real equity tier.
        ledger = read_ledger()
        ledger[selected.value] = {
            "status": "PASS",
            "build_marker": STEP19_BUILD_MARKER,
            "certified_ts": int(time.time()),
            "server": str(account.server),
            "symbol": "XAUUSD",
            "strategy_profile": profile.name,
            "position_ticket": int(cert_ticket),
            "signal_id": cert_key,
        }
        write_ledger(ledger)

        emit("STEP19_SELECTED_TIER_LIFECYCLE", "PASS")
        emit("STEP19_CERTIFIED_TIER", selected.value)

    except BaseException as exc:
        certification_error = exc

    finally:
        if opened and not closed_normally and cert_ticket:
            emergency_used = True
            try:
                emergency_ok = emergency_close(
                    cert_ticket,
                    int(bridge_settings.magic),
                )
            except BaseException:
                emergency_ok = False

            emit("STEP19_EMERGENCY_CLEANUP_USED", True)
            emit("STEP19_EMERGENCY_CLEANUP_SUCCESS", bool(emergency_ok))

            # If DB persistence happened, reconcile the emergency close too.
            if emergency_ok and persisted and account is not None:
                try:
                    deals = wait_history(
                        cert_ticket,
                        minimum=2,
                        seconds=20,
                    )
                    if deals:
                        worker.sync_deals(
                            deals,
                            account.login,
                            account.server,
                        )
                    emit("STEP19_FAILSAFE_DB_RECONCILIATION", "PASS")
                except BaseException:
                    emit("STEP19_FAILSAFE_DB_RECONCILIATION", "FAILED")

        # A failed certification must not leave the platform account's
        # assignment changed merely because persist_execution was exercised.
        if (
            certification_error is not None
            and account is not None
            and original_platform_tier is not None
        ):
            try:
                restore_platform_current_tier(
                    account.login,
                    account.server,
                    original_platform_tier,
                )
                emit("STEP19_FAILSAFE_CURRENT_TIER_RESTORED", "PASS")
            except BaseException:
                emit("STEP19_FAILSAFE_CURRENT_TIER_RESTORED", "FAILED")

        gateway.store = original_store
        bridge_settings.idempotency_db = original_db
        gateway.settings.idempotency_db = original_db

        bridge_settings.live_trading = original_live
        gateway.settings.live_trading = original_live
        bridge_settings.management_enabled = original_management
        gateway.settings.management_enabled = original_management
        bridge_settings.break_even_enabled = original_be_enabled
        gateway.settings.break_even_enabled = original_be_enabled
        bridge_settings.trailing_enabled = original_trailing_enabled
        gateway.settings.trailing_enabled = original_trailing_enabled
        bridge_settings.break_even_r = original_be_r
        gateway.settings.break_even_r = original_be_r
        bridge_settings.trail_start_r = original_trail_start
        gateway.settings.trail_start_r = original_trail_start
        bridge_settings.trail_distance_r = original_trail_distance
        gateway.settings.trail_distance_r = original_trail_distance

    if emergency_used:
        shutil.rmtree(temp_dir, ignore_errors=True)
        if emergency_ok:
            raise RuntimeError(
                "Step19 normal lifecycle failed; emergency cleanup succeeded. "
                "Exposure is safe but Step19 tier certification is NOT valid."
            ) from certification_error
        raise RuntimeError(
            "Step19 failed and emergency cleanup could not confirm zero exposure."
        ) from certification_error

    if certification_error is not None:
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise certification_error

    require(
        original_store.get(cert_key) is None,
        "Step19 certification key leaked into production idempotency store.",
    )
    require(
        not bool(original_store.claim_exists(cert_key)),
        "Step19 certification claim leaked into production idempotency store.",
    )
    emit("PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED", "PASS")

    shutil.rmtree(temp_dir, ignore_errors=True)
    emit("TEMP_CERTIFICATION_STORE_REMOVED", "PASS")
    emit("PROCESS_LOCAL_SETTINGS_RESTORED", "PASS")

    ledger = read_ledger()
    all_three = ledger_status(ledger)

    if all_three:
        emit("STEP_19", "PASS")
    else:
        emit("STEP_19", "PARTIAL")

    emit("LIVE_MONEY_AUTHORIZED", False)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("preflight", "demo"),
        default="preflight",
    )
    parser.add_argument(
        "--direction",
        choices=("BUY", "SELL"),
        default="BUY",
    )
    parser.add_argument(
        "--require-tier",
        choices=("SCALPER", "MASTER"),
        required=True,
    )
    parser.add_argument(
        "--mt5-path",
        required=True,
    )
    parser.add_argument(
        "--cert-login",
        required=True,
        help="Explicit IC Markets DEMO login authorized for this certification child process.",
    )
    args = parser.parse_args()

    emit("STEP19_BUILD_MARKER", STEP19_BUILD_MARKER)
    emit("MODE", args.mode.upper())
    emit("MARKET_SIGNAL_USED", False)
    emit("LIVE_MONEY_AUTHORIZED", False)
    emit("CERT_LOGIN_PRINTED", False)
    emit("PRODUCTION_ENV_CHANGED", False)

    require(core_settings.execution_enabled is False, "Production ABUTRON execution must remain false.")
    require(bridge_settings.live_trading is False, "Production MT5 live trading must remain false.")
    require(bridge_settings.management_enabled is False, "Production MT5 management must remain false.")
    require(bridge_settings.demo_only is True, "MT5_DEMO_ONLY must remain true.")

    cert_login = str(args.cert_login or "").strip()
    require(cert_login.isdigit(), "CERT_LOGIN_INVALID")

    if not mt5.initialize(path=args.mt5_path):
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    original_expected_login = bridge_settings.expected_login
    original_gateway_expected_login = gateway.settings.expected_login

    try:
        account_info = mt5.account_info()
        require(account_info is not None, "MT5 account_info unavailable.")

        actual_login = str(getattr(account_info, "login", "") or "").strip()
        actual_server = str(getattr(account_info, "server", "") or "").strip()

        require(
            actual_login == cert_login,
            "CERT_CONNECTED_LOGIN_DOES_NOT_MATCH_EXPLICIT_CERT_LOGIN",
        )

        expected_server = str(bridge_settings.expected_server or "").strip()
        require(bool(expected_server), "MT5_EXPECTED_SERVER_REQUIRED")
        require(
            actual_server.casefold() == expected_server.casefold(),
            "CERT_CONNECTED_SERVER_MISMATCH",
        )

        demo_mode = getattr(mt5, "ACCOUNT_TRADE_MODE_DEMO", 0)
        actual_trade_mode = int(getattr(account_info, "trade_mode", -1))
        require(
            actual_trade_mode == int(demo_mode),
            "CERT_ACCOUNT_IS_NOT_MT5_DEMO_MODE",
        )

        # Critical design rule:
        # Override only this child process's exact-login guard.
        # Production .env and the running production Bridge configuration are untouched.
        bridge_settings.expected_login = int(cert_login)
        gateway.settings.expected_login = int(cert_login)

        emit("CERT_CONNECTED_LOGIN_MATCH", "PASS")
        emit("CERT_CONNECTED_SERVER_MATCH", "PASS")
        emit("CERT_ACCOUNT_DEMO_MODE", "PASS")
        emit("CERT_EXPECTED_LOGIN_OVERRIDE", "PROCESS_LOCAL")
        emit("PRODUCTION_EXPECTED_LOGIN_UNCHANGED", True)

        if args.mode == "preflight":
            _, selected, _, _ = preflight(args.require_tier)
            ledger = read_ledger()
            emit("STEP19_SELECTED_TIER", selected.value)
            ledger_status(ledger)
            emit("STEP19_BUILD_PRECHECK", "PASS")
            emit("DEMO_ORDER_SENT", False)
            return 0

        direction = (
            Direction.BUY
            if args.direction == "BUY"
            else Direction.SELL
        )

        return demo_lifecycle(
            direction=direction,
            require_tier=args.require_tier,
        )

    finally:
        bridge_settings.expected_login = original_expected_login
        gateway.settings.expected_login = original_gateway_expected_login

        try:
            mt5.shutdown()
        except Exception:
            pass

        emit("CERT_EXPECTED_LOGIN_RESTORED", True)
        emit("PRODUCTION_ENV_CHANGED", False)


if __name__ == "__main__":
    raise SystemExit(main())
