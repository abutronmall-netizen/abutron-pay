from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx

from abutron.config import settings
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
from abutron.capital import make_order_plan
from abutron.profiles import profile_for
from abutron.risk import RiskEngine
from abutron.service import TradingService

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
CORE_URL = "http://127.0.0.1:8088"
MT5_URL = settings.mt5_url.rstrip("/")
SYMBOL = "XAUUSD"

def fail(msg: str) -> None:
    raise SystemExit(f"CERTIFICATION FAILED: {msg}")

if not settings.mt5_token or settings.mt5_token.startswith("CHANGE_ME"):
    fail("ABUTRON_MT5_TOKEN is not configured")

headers = {"Authorization": f"Bearer {settings.mt5_token}"}

with httpx.Client(timeout=20.0) as client:

    core_health = client.get(f"{CORE_URL}/health").json()
    bridge_health = client.get(f"{MT5_URL}/health").json()

    if core_health.get("execution_enabled") is not False:
        fail("ABUTRON_EXECUTION_ENABLED must remain false")

    if bridge_health.get("live_trading") is not False:
        fail("MT5_LIVE_TRADING must remain false")

    if bridge_health.get("management_enabled") is not False:
        fail("MT5_MANAGEMENT_ENABLED must remain false")

    r = client.get(f"{MT5_URL}/v1/account", headers=headers)
    r.raise_for_status()
    account = AccountState(**r.json())

    r = client.get(f"{MT5_URL}/v1/context/{SYMBOL}", headers=headers)
    r.raise_for_status()
    broker = BrokerContext(**r.json())

    r = client.get(f"{MT5_URL}/v1/positions", headers=headers)
    r.raise_for_status()
    positions_before = r.json()

    account.license_active = TradingService._platform_license_for_login(account.login)

    if not account.license_active:
        fail("platform license is not active for connected MT5 login")

    if broker.positions_on_symbol != 0:
        fail(
            f"{SYMBOL} has {broker.positions_on_symbol} open position(s); "
            "certification requires a flat symbol"
        )

    now = int(time.time())
    px = float(broker.bid)

    candle = Candle(
        ts=now,
        open=px,
        high=px,
        low=px,
        close=px,
        volume=1.0
    )

    market = MarketBundle(
        primary=MarketSnapshot(
            symbol=SYMBOL,
            timeframe="M1",
            candles=[candle],
            spread_points=broker.spread_points,
            received_ts=now
        ),
        contexts={}
    )

    thesis = Thesis(
        symbol=SYMBOL,
        direction=Direction.BUY,
        confidence=99.0,
        score=1.0,
        valid=True,
        reason="CERTIFICATION_SYNTHETIC_ONLY",
        regime="CERTIFICATION",
        evidence={
            "synthetic": True,
            "purpose": "RISK_CAPITAL_ORDER_CHECK"
        }
    )

    risk = RiskEngine().evaluate(
        thesis=thesis,
        account=account,
        broker=broker,
        market=market,
        tier=BotTier.FLIPPER
    )

    if not risk.approved:
        fail(f"risk engine blocked certification: {risk.reason}")

    profile = profile_for(BotTier.FLIPPER)

    risk_target = min(
        account.equity * (profile.risk_pct / 100.0),
        risk.max_risk_amount
    )

    denom = (
        profile.sl_atr
        * broker.tick_value
        * broker.volume_min
    )

    if risk_target <= 0 or broker.tick_size <= 0 or denom <= 0:
        fail("invalid broker/risk inputs")

    cert_atr = (
        0.50
        * risk_target
        * broker.tick_size
        / denom
    )

    features = FeatureVector(
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
        atr=cert_atr,
        metadata={"synthetic": True}
    )

    plan = make_order_plan(
        thesis=thesis,
        features=features,
        account=account,
        broker=broker,
        risk=risk,
        bar_ts=now,
        tier=BotTier.FLIPPER
    )

    if plan is None:
        fail("capital engine returned no OrderPlan")

    if plan.volume < broker.volume_min - 1e-12:
        fail("capital volume below broker minimum")

    if plan.volume > broker.volume_max + 1e-12:
        fail("capital volume above broker maximum")

    if plan.risk_amount > risk.max_risk_amount + 1e-9:
        fail("capital plan exceeds RiskEngine authorization")

    if plan.risk_amount > risk_target + 1e-9:
        fail("capital plan exceeds strategy risk target")

    source = (ROOT / "mt5_bridge" / "app.py").read_text(
        encoding="utf-8"
    )

    start = source.find('@app.post("/v1/order-check")')
    end = source.find('@app.post("/v1/order")', start + 1)

    if start < 0 or end < 0:
        fail("cannot isolate /v1/order-check source")

    check_source = source[start:end]

    if "order_send(" in check_source:
        fail("/v1/order-check contains order_send()")

    r = client.post(
        f"{MT5_URL}/v1/order-check",
        headers=headers,
        json=plan.model_dump(mode="json")
    )

    r.raise_for_status()
    check_result = r.json()

    if check_result.get("order_sent") is not False:
        fail("order_sent was not false")

    if check_result.get("checked") is not True:
        fail("checked was not true")

    time.sleep(0.25)

    r = client.get(
        f"{MT5_URL}/v1/positions",
        headers=headers
    )
    r.raise_for_status()
    positions_after = r.json()

before_tickets = sorted(
    int(x.get("ticket", 0))
    for x in positions_before
)

after_tickets = sorted(
    int(x.get("ticket", 0))
    for x in positions_after
)

if before_tickets != after_tickets:
    fail("positions changed during certification")

passed = bool(check_result.get("check_passed"))

evidence = {
    "certification": "ABUTRON_V4_RISK_CAPITAL_MT5_ORDER_CHECK",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),

    "status": (
        "PASS"
        if passed
        else "BROKER_CHECK_REJECTED"
    ),

    "safety": {
        "core_execution_enabled":
            core_health.get("execution_enabled"),

        "mt5_live_trading":
            bridge_health.get("live_trading"),

        "mt5_management_enabled":
            bridge_health.get("management_enabled"),

        "order_send_absent_from_order_check_source":
            True,

        "positions_unchanged":
            before_tickets == after_tickets
    },

    "account": {
        "login": account.login,
        "server": account.server,
        "currency": account.currency,
        "equity": account.equity,
        "balance": account.balance,
        "daily_pnl": account.daily_pnl,
        "open_risk": account.open_risk,
        "license_active": account.license_active
    },

    "broker":
        broker.model_dump(mode="json"),

    "synthetic_inputs": {
        "direction": thesis.direction.value,
        "confidence": thesis.confidence,
        "atr": cert_atr,
        "note":
            "Certification-only synthetic thesis; "
            "not a market trading signal."
    },

    "risk":
        risk.model_dump(mode="json"),

    "risk_target":
        risk_target,

    "plan":
        plan.model_dump(mode="json"),

    "order_check":
        check_result,

    "positions_before":
        before_tickets,

    "positions_after":
        after_tickets
}

logs = ROOT / "logs"
logs.mkdir(parents=True, exist_ok=True)

out = logs / (
    "order-check-certification-"
    + datetime.now().strftime("%Y%m%d-%H%M%S")
    + ".json"
)

out.write_text(
    json.dumps(evidence, indent=2),
    encoding="utf-8"
)

print(json.dumps(evidence, indent=2))
print(f"\nEVIDENCE_FILE={out}")

if not passed:
    raise SystemExit(
        "BROKER ORDER_CHECK REJECTED: "
        f"retcode={check_result.get('retcode')} "
        f"comment={check_result.get('comment')}"
    )

print(
    "\nCERTIFICATION PASS: "
    "Risk -> Capital -> MT5 order_check; "
    "no order sent."
)