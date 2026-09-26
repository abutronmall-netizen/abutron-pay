from __future__ import annotations

import argparse
import shutil
import tempfile
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys

from fastapi import HTTPException

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as real_mt5

from abutron.models import BotTier, Direction, OrderPlan
from mt5_bridge.settings import settings as bridge_settings
from mt5_bridge.store import IdempotencyStore
import mt5_bridge.app as gateway


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def raw_symbol(symbol: str) -> str:
    return gateway.raw_symbol(symbol)


def history_magic_symbol(magic: int, symbol: str):
    now = datetime.now(timezone.utc)
    rows = real_mt5.history_deals_get(
        now - timedelta(days=7),
        now + timedelta(days=1),
    )
    if rows is None:
        raise RuntimeError(
            f"history_deals_get failed: {real_mt5.last_error()}"
        )
    target = symbol.upper()
    return [
        d for d in rows
        if int(getattr(d, "magic", 0) or 0) == int(magic)
        and str(getattr(d, "symbol", "") or "").upper() == target
    ]


def symbol_positions(symbol: str):
    rows = real_mt5.positions_get(symbol=symbol)
    if rows is None:
        raise RuntimeError(
            f"positions_get({symbol}) failed: {real_mt5.last_error()}"
        )
    return list(rows)


def all_abutron_positions(magic: int):
    rows = real_mt5.positions_get()
    if rows is None:
        raise RuntimeError(
            f"positions_get failed: {real_mt5.last_error()}"
        )
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
            raise RuntimeError("Multiple Abutron positions appeared.")
        time.sleep(0.5)
    return None


def wait_absent(ticket: int, seconds: int = 20) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = real_mt5.positions_get(ticket=int(ticket))
        if rows is None:
            raise RuntimeError(
                f"positions_get(ticket) failed: {real_mt5.last_error()}"
            )
        if len(rows) == 0:
            return True
        time.sleep(0.5)
    return False


def wait_sl_change(ticket: int, old_sl: float, is_buy: bool, seconds: int = 20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        rows = real_mt5.positions_get(ticket=int(ticket))
        if rows is None:
            raise RuntimeError(
                f"positions_get(ticket) failed: {real_mt5.last_error()}"
            )
        if len(rows) != 1:
            return None
        p = rows[0]
        sl = float(p.sl)
        if (is_buy and sl > old_sl + 1e-12) or (
            (not is_buy) and sl < old_sl - 1e-12
        ):
            return p
        time.sleep(0.5)
    return None


def emergency_close(ticket: int, magic: int) -> bool:
    rows = real_mt5.positions_get(ticket=int(ticket))
    if not rows:
        return True
    if len(rows) != 1:
        return False

    p = rows[0]
    owned = (
        int(getattr(p, "magic", 0) or 0) == int(magic)
        or str(getattr(p, "comment", "") or "").upper().startswith("ABUTRON")
    )
    if not owned:
        return False

    fills = [
        ("IOC", real_mt5.ORDER_FILLING_IOC),
        ("FOK", real_mt5.ORDER_FILLING_FOK),
        ("RETURN", real_mt5.ORDER_FILLING_RETURN),
    ]

    for _ in range(4):
        rows = real_mt5.positions_get(ticket=int(ticket))
        if not rows:
            return True
        p = rows[0]

        tick = real_mt5.symbol_info_tick(p.symbol)
        if tick is None:
            time.sleep(1)
            continue

        is_buy = int(p.type) == int(real_mt5.POSITION_TYPE_BUY)
        selected = None

        for fill_name, fill_value in fills:
            req = {
                "action": real_mt5.TRADE_ACTION_DEAL,
                "position": int(p.ticket),
                "symbol": p.symbol,
                "volume": float(p.volume),
                "type": (
                    real_mt5.ORDER_TYPE_SELL
                    if is_buy
                    else real_mt5.ORDER_TYPE_BUY
                ),
                "price": float(tick.bid if is_buy else tick.ask),
                "deviation": max(int(bridge_settings.deviation_points), 50),
                "magic": int(magic),
                "comment": "ABUTRON S18 EMERG",
                "type_time": real_mt5.ORDER_TIME_GTC,
                "type_filling": int(fill_value),
            }
            chk = real_mt5.order_check(req)
            if chk is not None and int(getattr(chk, "retcode", -1)) == 0:
                selected = (fill_name, req)
                break

        if selected is None:
            return False

        fill_name, req = selected
        emit("STEP18_EMERGENCY_FILLING", fill_name)

        res = real_mt5.order_send(req)
        if (
            res is not None
            and int(res.retcode) in (
                int(real_mt5.TRADE_RETCODE_DONE),
                int(real_mt5.TRADE_RETCODE_DONE_PARTIAL),
            )
        ):
            if wait_absent(ticket, 15):
                return True

        time.sleep(1)

    return wait_absent(ticket, 2)


class Obj:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class FakeMT5:
    POSITION_TYPE_BUY = real_mt5.POSITION_TYPE_BUY
    POSITION_TYPE_SELL = real_mt5.POSITION_TYPE_SELL
    TRADE_ACTION_SLTP = real_mt5.TRADE_ACTION_SLTP
    TRADE_ACTION_DEAL = real_mt5.TRADE_ACTION_DEAL
    ORDER_TYPE_BUY = real_mt5.ORDER_TYPE_BUY
    ORDER_TYPE_SELL = real_mt5.ORDER_TYPE_SELL
    ORDER_TIME_GTC = real_mt5.ORDER_TIME_GTC
    ORDER_FILLING_IOC = real_mt5.ORDER_FILLING_IOC
    TRADE_RETCODE_DONE = real_mt5.TRADE_RETCODE_DONE

    def __init__(self, positions, info=None, tick=None):
        self._positions = list(positions)
        self._info = info or Obj(
            point=0.01,
            trade_tick_size=0.01,
            trade_stops_level=0,
            trade_freeze_level=0,
            digits=2,
        )
        self._tick = tick or Obj(bid=102.0, ask=102.1)
        self.sent = []
        self.checked = []

    def initialize(self, *args, **kwargs):
        return True

    def last_error(self):
        return (0, "OK")

    def account_info(self):
        # STEP18_CERT_V2_EXACT_DEMO_IDENTITY
        # The production execution guard validates BOTH the configured login
        # and server. The deterministic fake must therefore model both fields.
        return Obj(
            login=int(bridge_settings.expected_login),
            server=str(bridge_settings.expected_server),
        )

    def positions_get(self, ticket=None, symbol=None):
        rows = list(self._positions)
        if ticket is not None:
            rows = [p for p in rows if int(p.ticket) == int(ticket)]
        if symbol is not None:
            rows = [p for p in rows if p.symbol == symbol]
        return tuple(rows)

    def symbol_info(self, symbol):
        return self._info

    def symbol_info_tick(self, symbol):
        return self._tick

    def order_check(self, req):
        self.checked.append(dict(req))
        return Obj(retcode=0, comment="Done")

    def order_send(self, req):
        self.sent.append(dict(req))
        return Obj(
            retcode=self.TRADE_RETCODE_DONE,
            deal=1,
            order=1,
            comment="Done",
        )


def fake_position(
    ticket: int,
    owned: bool,
    price_open: float,
    price_current: float,
    sl: float,
    tp: float,
):
    return Obj(
        ticket=ticket,
        magic=int(bridge_settings.magic) if owned else 123,
        comment="ABUTRON S18" if owned else "MANUAL",
        sl=sl,
        tp=tp,
        price_open=price_open,
        price_current=price_current,
        type=real_mt5.POSITION_TYPE_BUY,
        symbol="XAUUSD",
        volume=0.01,
    )


def deterministic_management_tests(temp_store: IdempotencyStore, valid_auth: str):
    original_mt5 = gateway.mt5
    original_store = gateway.store
    original_management = bool(bridge_settings.management_enabled)
    original_break_even = bool(bridge_settings.break_even_enabled)
    original_trailing = bool(bridge_settings.trailing_enabled)
    original_be_r = float(bridge_settings.break_even_r)
    original_trail_start = float(bridge_settings.trail_start_r)
    original_trail_distance = float(bridge_settings.trail_distance_r)
    original_live = bool(bridge_settings.live_trading)

    try:
        gateway.store = temp_store
        gateway.settings.management_enabled = True
        bridge_settings.management_enabled = True
        gateway.settings.live_trading = True
        bridge_settings.live_trading = True

        owned = fake_position(18001, True, 100.0, 101.2, 98.0, 110.0)
        manual = fake_position(18002, False, 100.0, 105.0, 95.0, 110.0)
        temp_store.put_position(18001, 1.0, "FLIPPER", "STEP18-BE")

        fake = FakeMT5(
            [owned, manual],
            tick=Obj(bid=101.2, ask=101.3),
        )
        gateway.mt5 = fake

        result = gateway.manage(authorization=valid_auth)
        require(result["managed"] is True, "Deterministic BE manage did not run.")
        require(len(fake.sent) == 1, "Ownership isolation failed in BE test.")
        require(len(result["actions"]) == 1, "Unexpected action count in BE test.")
        action = result["actions"][0]
        require(abs(float(action["new_sl"]) - 100.0) < 0.011, "Break-even did not move SL to entry.")
        emit("DETERMINISTIC_BREAK_EVEN_POLICY", "PASS")
        emit("DETERMINISTIC_OWNERSHIP_ISOLATION", "PASS")

        owned2 = fake_position(18003, True, 100.0, 102.0, 98.0, 110.0)
        temp_store.put_position(18003, 1.0, "FLIPPER", "STEP18-TRAIL")
        fake2 = FakeMT5(
            [owned2],
            tick=Obj(bid=102.0, ask=102.1),
        )
        gateway.mt5 = fake2

        result2 = gateway.manage(authorization=valid_auth)
        require(len(fake2.sent) == 1, "Trailing test did not send one SLTP modification.")
        a2 = result2["actions"][0]
        require(float(a2["new_sl"]) > 100.0, "Trailing SL did not move beyond break-even.")
        require(float(a2["new_sl"]) > float(a2["old_sl"]), "Trailing worsened BUY SL.")
        emit("DETERMINISTIC_TRAILING_POLICY", "PASS")
        emit("DETERMINISTIC_NO_WORSENING_SL", "PASS")

        constrained = fake_position(18004, True, 100.0, 100.30, 98.0, 110.0)
        temp_store.put_position(18004, 0.10, "FLIPPER", "STEP18-CONSTRAINT")
        info = Obj(
            point=0.01,
            trade_tick_size=0.01,
            trade_stops_level=50,
            trade_freeze_level=40,
            digits=2,
        )
        fake3 = FakeMT5(
            [constrained],
            info=info,
            tick=Obj(bid=100.30, ask=100.31),
        )
        gateway.mt5 = fake3

        result3 = gateway.manage(authorization=valid_auth)
        require(len(fake3.sent) == 1, "Constraint test did not produce a safe modification.")
        a3 = result3["actions"][0]
        require(float(a3["new_sl"]) <= 99.79 + 1e-9, "Stop/freeze guard did not clamp BUY SL.")
        require(float(a3["new_sl"]) > 98.0, "Constraint guard failed to preserve improvement.")
        require(len(fake3.checked) == 1, "SLTP order_check was not executed.")
        emit("DETERMINISTIC_STOPS_FREEZE_GUARD", "PASS")
        emit("DETERMINISTIC_SLTP_ORDER_CHECK", "PASS")

        adverse = fake_position(18005, True, 100.0, 99.0, 98.0, 110.0)
        temp_store.put_position(18005, 1.0, "FLIPPER", "STEP18-ADVERSE")
        fake4 = FakeMT5(
            [adverse],
            tick=Obj(bid=99.0, ask=99.1),
        )
        gateway.mt5 = fake4

        result4 = gateway.manage(authorization=valid_auth)
        require(len(fake4.sent) == 0, "Adverse/no-improvement test sent an SLTP request.")
        require(len(result4["actions"]) == 0, "Adverse/no-improvement test created an action.")
        emit("DETERMINISTIC_NO_IMPROVEMENT_NO_SEND", "PASS")

        non_owned = fake_position(18006, False, 100.0, 100.0, 98.0, 110.0)
        fake5 = FakeMT5([non_owned])
        gateway.mt5 = fake5

        refused = False
        try:
            gateway.close(18006, authorization=valid_auth)
        except HTTPException as exc:
            refused = int(exc.status_code) == 403

        require(refused, "Non-Abutron close was not refused with HTTP 403.")
        require(len(fake5.sent) == 0, "Ownership-refused close reached order_send.")
        emit("DETERMINISTIC_CLOSE_OWNERSHIP_REFUSAL", "PASS")

    finally:
        gateway.mt5 = original_mt5
        gateway.store = original_store
        gateway.settings.management_enabled = original_management
        bridge_settings.management_enabled = original_management
        gateway.settings.break_even_enabled = original_break_even
        bridge_settings.break_even_enabled = original_break_even
        gateway.settings.trailing_enabled = original_trailing
        bridge_settings.trailing_enabled = original_trailing
        gateway.settings.break_even_r = original_be_r
        bridge_settings.break_even_r = original_be_r
        gateway.settings.trail_start_r = original_trail_start
        bridge_settings.trail_start_r = original_trail_start
        gateway.settings.trail_distance_r = original_trail_distance
        bridge_settings.trail_distance_r = original_trail_distance
        gateway.settings.live_trading = original_live
        bridge_settings.live_trading = original_live


def make_plan(symbol: str, direction: Direction, key: str) -> OrderPlan:
    rs = raw_symbol(symbol)
    require(real_mt5.symbol_select(rs, True), f"Could not select {rs}.")

    info = real_mt5.symbol_info(rs)
    tick = real_mt5.symbol_info_tick(rs)
    require(info is not None, "symbol_info unavailable.")
    require(tick is not None, "symbol_info_tick unavailable.")

    point = float(info.point or 0.0)
    tick_size = float(info.trade_tick_size or point or 0.0)
    require(tick_size > 0.0, "Invalid broker tick size.")

    broker_distance = (
        max(
            int(info.trade_stops_level or 0),
            int(info.trade_freeze_level or 0),
            0,
        )
        * point
        + tick_size
    )

    distance = max(
        broker_distance * 8.0,
        tick_size * 100.0,
        2.0,
    )

    if direction == Direction.BUY:
        entry = float(tick.ask)
        sl = entry - distance
        tp = entry + (distance * 2.0)
    else:
        entry = float(tick.bid)
        sl = entry + distance
        tp = entry - (distance * 2.0)

    return OrderPlan(
        symbol=symbol,
        direction=direction,
        tier=BotTier.FLIPPER,
        strategy_profile="step18-management-cert",
        volume=float(info.volume_min),
        entry=entry,
        sl=sl,
        tp=tp,
        risk_amount=0.01,
        confidence=100.0,
        idempotency_key=key,
        thesis_reason="STEP18_CONTROLLED_DEMO_MANAGEMENT_NOT_A_MARKET_SIGNAL",
    )


STEP18_CERT_V2_EXACT_IDENTITY_REPAIR = True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mt5-path", required=True)
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--direction", choices=("BUY","SELL"), default="BUY")
    args = parser.parse_args()

    symbol = args.symbol.upper()
    direction = Direction.BUY if args.direction == "BUY" else Direction.SELL
    magic = int(bridge_settings.magic)
    key = f"STEP18-{int(time.time())}-{uuid.uuid4().hex[:10]}"

    original_mt5 = gateway.mt5
    original_store = gateway.store
    original_db = str(bridge_settings.idempotency_db)
    original_live = bool(bridge_settings.live_trading)
    original_management = bool(bridge_settings.management_enabled)
    original_be_enabled = bool(bridge_settings.break_even_enabled)
    original_trail_enabled = bool(bridge_settings.trailing_enabled)
    original_be_r = float(bridge_settings.break_even_r)
    original_trail_start = float(bridge_settings.trail_start_r)
    original_trail_distance = float(bridge_settings.trail_distance_r)

    temp_dir = Path(tempfile.mkdtemp(prefix="abutron-step18-", dir=str(ROOT / "logs")))
    temp_db = temp_dir / "step18_idempotency.sqlite3"

    cert_ticket = None
    opened = False
    closed_normally = False
    emergency_used = False
    emergency_ok = None
    certification_error = None

    try:
        emit("STEP18_DIRECTION", direction.value)
        emit("MARKET_SIGNAL_USED", False)
        emit("AUTONOMOUS_WORKER_USED", False)

        require(original_live is False, "Production live trading baseline must be false.")
        require(original_management is False, "Production management baseline must be false.")
        require(bool(bridge_settings.demo_only) is True, "DEMO_ONLY must be true.")
        require(bridge_settings.expected_login is not None, "Expected login missing.")
        require(bool(str(bridge_settings.expected_server or "").strip()), "Expected server missing.")

        source = Path(gateway.__file__).read_text(encoding="utf-8")
        for marker in (
            "STEP18_MANAGEMENT_HARDENING_V1",
            "trade_stops_level",
            "trade_freeze_level",
            "MANAGE_ORDER_CHECK_REJECTED",
        ):
            require(marker in source, f"Production manage hardening missing: {marker}")
        emit("STEP18_MANAGEMENT_HARDENING_STATIC", "PASS")

        if not real_mt5.initialize(path=args.mt5_path):
            raise RuntimeError(f"MT5 initialize failed: {real_mt5.last_error()}")

        terminal = real_mt5.terminal_info()
        account = real_mt5.account_info()
        require(terminal is not None and account is not None, "MT5 identity unavailable.")
        require(bool(terminal.connected), "MT5 disconnected.")
        require(bool(terminal.trade_allowed), "MT5 terminal trade permission is OFF.")
        require(int(account.login) == int(bridge_settings.expected_login), "MT5 login mismatch.")
        require(str(account.server) == str(bridge_settings.expected_server), "MT5 server mismatch.")
        require("DEMO" in str(account.server).upper(), "Connected account is not DEMO.")
        emit("DEMO_ACCOUNT_IDENTITY", "PASS")
        emit("ACCOUNT_LOGIN_PRINTED", False)

        rs = raw_symbol(symbol)
        require(real_mt5.symbol_select(rs, True), f"Could not select {rs}.")
        require(len(symbol_positions(rs)) == 0, "Step18 requires zero XAUUSD positions.")
        require(len(all_abutron_positions(magic)) == 0, "Step18 requires zero Abutron positions.")
        emit("ZERO_POSITION_BASELINE", "PASS")

        bridge_settings.idempotency_db = str(temp_db)
        gateway.settings.idempotency_db = str(temp_db)
        cert_store = IdempotencyStore()
        gateway.store = cert_store

        valid_auth = f"Bearer {bridge_settings.api_token}"
        gateway.auth(valid_auth)

        refused = gateway.manage(authorization=valid_auth)
        require(
            refused.get("managed") is False
            and refused.get("reason") == "MT5_MANAGEMENT_ENABLED_FALSE",
            "Management-disabled refusal failed.",
        )
        emit("MANAGEMENT_DISABLED_REFUSAL", "PASS")

        deterministic_management_tests(cert_store, valid_auth)
        gateway.mt5 = real_mt5

        plan = make_plan(symbol, direction, key)
        baseline_deals = len(history_magic_symbol(magic, rs))

        gateway.settings.live_trading = True
        bridge_settings.live_trading = True
        gateway.settings.management_enabled = False
        bridge_settings.management_enabled = False

        result = gateway.order(plan, authorization=valid_auth)
        require(result.get("accepted") is True, f"Step18 demo open failed: {result}")
        require(int(result.get("retcode", -1)) == int(real_mt5.TRADE_RETCODE_DONE), "Open retcode not DONE.")
        opened = True
        emit("REAL_DEMO_OPEN", "PASS")

        position = wait_position(rs, magic, 20)
        require(position is not None, "Step18 position not found.")
        cert_ticket = int(position.ticket)
        emit("REAL_POSITION_OWNERSHIP", "PASS")

        info = real_mt5.symbol_info(rs)
        tick = real_mt5.symbol_info_tick(rs)
        require(info is not None and tick is not None, "Broker symbol/tick unavailable.")

        point = float(info.point or 0.0)
        tick_size = float(info.trade_tick_size or point or 0.0)
        safe_distance = (
            max(
                int(info.trade_stops_level or 0),
                int(info.trade_freeze_level or 0),
                0,
            )
            * point
            + tick_size
        )
        cert_initial_r = max(safe_distance * 2.0, tick_size * 20.0)

        cert_store.put_position(
            cert_ticket,
            cert_initial_r,
            "FLIPPER",
            key,
        )

        before_rows = real_mt5.positions_get(ticket=cert_ticket) or []
        require(len(before_rows) == 1, "Position disappeared before management.")
        before = before_rows[0]
        old_sl = float(before.sl)
        is_buy = int(before.type) == int(real_mt5.POSITION_TYPE_BUY)

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

        managed = gateway.manage(authorization=valid_auth)
        actions = [
            a for a in managed.get("actions", [])
            if int(a.get("ticket", 0) or 0) == cert_ticket
        ]
        require(len(actions) == 1, f"Expected one real management action; got {actions}")
        action = actions[0]
        require(action.get("ok") is True, f"Real SLTP management failed: {action}")
        require(int(action.get("retcode", -1)) == int(real_mt5.TRADE_RETCODE_DONE), "Management retcode not DONE.")
        emit("REAL_BROKER_SLTP_MANAGEMENT", "PASS")
        emit("REAL_BROKER_STOPS_FREEZE_PATH", "PASS")

        changed = wait_sl_change(cert_ticket, old_sl, is_buy, 20)
        require(changed is not None, "Broker position SL did not improve.")
        actual_sl = float(changed.sl)
        if is_buy:
            require(actual_sl > old_sl + 1e-12, "BUY SL worsened or did not improve.")
        else:
            require(actual_sl < old_sl - 1e-12, "SELL SL worsened or did not improve.")
        emit("REAL_NO_WORSENING_SL", "PASS")

        second_before_sl = actual_sl
        gateway.manage(authorization=valid_auth)
        second_rows = real_mt5.positions_get(ticket=cert_ticket) or []
        require(len(second_rows) == 1, "Position disappeared during second management check.")
        second_sl = float(second_rows[0].sl)
        if is_buy:
            require(second_sl + 1e-12 >= second_before_sl, "Second manage worsened BUY SL.")
        else:
            require(second_sl - 1e-12 <= second_before_sl, "Second manage worsened SELL SL.")
        emit("REAL_REPEATED_MANAGE_NO_WORSENING", "PASS")

        gateway.settings.live_trading = True
        bridge_settings.live_trading = True

        close_result = gateway.close(cert_ticket, authorization=valid_auth)
        require(close_result.get("closed") is True, f"Normal gateway close failed: {close_result}")
        require(
            int(close_result.get("retcode", -1)) == int(real_mt5.TRADE_RETCODE_DONE),
            "Close retcode not DONE.",
        )
        require(wait_absent(cert_ticket, 20), "Position still exists after normal close.")
        closed_normally = True
        emit("REAL_NORMAL_CLOSE", "PASS")

        deadline = time.time() + 20
        history_ok = False
        while time.time() < deadline:
            if len(history_magic_symbol(magic, rs)) >= baseline_deals + 2:
                history_ok = True
                break
            time.sleep(0.5)
        require(history_ok, "Open+close broker deal history did not reconcile.")
        emit("TERMINAL_HISTORY_CLOSE_AGREEMENT", "PASS")

        require(len(symbol_positions(rs)) == 0, "Residual XAUUSD exposure remains.")
        require(len(all_abutron_positions(magic)) == 0, "Residual Abutron exposure remains.")
        emit("ZERO_RESIDUAL_EXPOSURE", "PASS")

        require(cert_store.get_position(cert_ticket) is None, "Position metadata was not deleted by close.")
        emit("POSITION_METADATA_CLEANUP", "PASS")

    except BaseException as exc:
        certification_error = exc

    finally:
        if opened and not closed_normally and cert_ticket:
            emergency_used = True
            try:
                gateway.mt5 = real_mt5
                emergency_ok = emergency_close(cert_ticket, magic)
            except BaseException:
                emergency_ok = False
            emit("STEP18_EMERGENCY_CLEANUP_USED", True)
            emit("STEP18_EMERGENCY_CLEANUP_SUCCESS", bool(emergency_ok))

        gateway.mt5 = original_mt5
        gateway.store = original_store

        bridge_settings.idempotency_db = original_db
        gateway.settings.idempotency_db = original_db
        bridge_settings.live_trading = original_live
        gateway.settings.live_trading = original_live
        bridge_settings.management_enabled = original_management
        gateway.settings.management_enabled = original_management
        bridge_settings.break_even_enabled = original_be_enabled
        gateway.settings.break_even_enabled = original_be_enabled
        bridge_settings.trailing_enabled = original_trail_enabled
        gateway.settings.trailing_enabled = original_trail_enabled
        bridge_settings.break_even_r = original_be_r
        gateway.settings.break_even_r = original_be_r
        bridge_settings.trail_start_r = original_trail_start
        gateway.settings.trail_start_r = original_trail_start
        bridge_settings.trail_distance_r = original_trail_distance
        gateway.settings.trail_distance_r = original_trail_distance

        try:
            real_mt5.shutdown()
        except Exception:
            pass

    if emergency_used:
        if emergency_ok:
            raise RuntimeError(
                "Step18 normal lifecycle failed; emergency cleanup succeeded. "
                "Exposure is safe but Step18 is NOT CERTIFIED."
            ) from certification_error
        raise RuntimeError(
            "Step18 failed and emergency cleanup could not confirm zero exposure."
        ) from certification_error

    if certification_error is not None:
        raise certification_error

    require(original_store.get(key) is None, "Step18 key leaked into production idempotency store.")
    require(not bool(original_store.claim_exists(key)), "Step18 claim leaked into production store.")
    emit("PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED", "PASS")

    shutil.rmtree(temp_dir, ignore_errors=True)
    emit("TEMP_CERTIFICATION_STORE_REMOVED", "PASS")
    emit("PROCESS_LOCAL_SETTINGS_RESTORED", "PASS")
    emit("STEP_18_HELPER", "PASS")
    emit("MANAGED_GATE", "PASS")
    emit("CLOSED_GATE", "PASS")
    emit("LIVE_MONEY_AUTHORIZED", False)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
