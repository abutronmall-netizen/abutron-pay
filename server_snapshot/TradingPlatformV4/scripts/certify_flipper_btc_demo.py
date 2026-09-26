from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import MetaTrader5 as mt5

from abutron.capital import make_order_plan
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
from abutron.profiles import profile_for
from abutron.risk import RiskEngine
from abutron.service import TradingService
from mt5_bridge.settings import settings as gw_settings


ROOT = Path(r"C:\Abutron\TradingPlatformV4")
BASE = "http://127.0.0.1:8090"
CORE = "http://127.0.0.1:8088"
SYMBOL = "BTCUSD"

logs = ROOT / "logs"
logs.mkdir(parents=True, exist_ok=True)

outfile = logs / (
    "flipper-btc-demo-lifecycle-"
    + datetime.now().strftime("%Y%m%d-%H%M%S")
    + ".json"
)

evidence = {
    "certification": "ABUTRON_V4_FLIPPER_BTCUSD_DEMO_LIFECYCLE",
    "started_utc": datetime.now(timezone.utc).isoformat(),
    "status": "STARTED",
    "checkpoints": [],
}

opened_ticket = 0


def save():
    outfile.write_text(
        json.dumps(evidence, indent=2, default=str),
        encoding="utf-8",
    )


def checkpoint(name, detail=None):
    row = {
        "name": name,
        "utc": datetime.now(timezone.utc).isoformat(),
    }

    if detail is not None:
        row["detail"] = detail

    evidence["checkpoints"].append(row)
    save()

    print(
        f"CHECKPOINT {name}"
        + (
            f" | {detail}"
            if detail is not None
            else ""
        ),
        flush=True,
    )


def fail(message):
    raise RuntimeError(message)


def call(
    client,
    name,
    method,
    path,
    *,
    timeout=30.0,
    **kwargs,
):
    checkpoint(name + ":start")

    start = time.perf_counter()

    try:
        r = client.request(
            method,
            BASE + path,
            headers=headers,
            timeout=timeout,
            **kwargs,
        )

    except Exception as exc:
        checkpoint(
            name + ":exception",
            repr(exc),
        )
        raise

    elapsed = round(
        time.perf_counter() - start,
        3,
    )

    checkpoint(
        name + ":response",
        {
            "status_code": r.status_code,
            "seconds": elapsed,
        },
    )

    return r


def get_positions(client):
    r = call(
        client,
        "positions",
        "GET",
        "/v1/positions",
    )

    r.raise_for_status()
    return r.json()


def owned(p):
    return (
        int(p.get("magic", 0) or 0)
        == gw_settings.magic
        or str(
            p.get("comment", "")
        ).upper().startswith("ABUTRON")
    )


def btc_positions(rows):
    return [
        p
        for p in rows
        if str(
            p.get("symbol", "")
        ).upper().startswith("BTCUSD")
    ]


def ticket_exists(client, ticket):
    return any(
        int(p.get("ticket", 0))
        == int(ticket)
        for p in get_positions(client)
    )


def direct_demo_cleanup(ticket):
    if not ticket:
        return {
            "needed": False
        }

    if not mt5.initialize():
        return {
            "needed": True,
            "error":
                f"MT5 init failed: {mt5.last_error()}",
        }

    try:
        a = mt5.account_info()

        if a is None:
            return {
                "needed": True,
                "error": "No account",
            }

        if "DEMO" not in str(
            a.server
        ).upper():
            return {
                "needed": True,
                "error":
                    f"REFUSED NON-DEMO: {a.server}",
            }

        rows = (
            mt5.positions_get(
                ticket=int(ticket)
            )
            or []
        )

        if not rows:
            return {
                "needed": False,
                "reason":
                    "position already absent",
            }

        p = rows[0]

        position_owned = (
            int(
                getattr(
                    p,
                    "magic",
                    0,
                )
                or 0
            )
            == gw_settings.magic
            or str(
                getattr(
                    p,
                    "comment",
                    "",
                )
            ).upper().startswith(
                "ABUTRON"
            )
        )

        if not position_owned:
            return {
                "needed": True,
                "error":
                    "REFUSED NON-ABUTRON POSITION",
            }

        tick = mt5.symbol_info_tick(
            p.symbol
        )

        if tick is None:
            return {
                "needed": True,
                "error": "No cleanup tick",
            }

        is_buy = (
            p.type
            == mt5.POSITION_TYPE_BUY
        )

        request = {
            "action":
                mt5.TRADE_ACTION_DEAL,

            "position":
                int(p.ticket),

            "symbol":
                p.symbol,

            "volume":
                float(p.volume),

            "type":
                (
                    mt5.ORDER_TYPE_SELL
                    if is_buy
                    else mt5.ORDER_TYPE_BUY
                ),

            "price":
                (
                    tick.bid
                    if is_buy
                    else tick.ask
                ),

            "deviation":
                gw_settings.deviation_points,

            "magic":
                gw_settings.magic,

            "comment":
                "ABUTRON CERT CLEANUP",

            "type_time":
                mt5.ORDER_TIME_GTC,

            "type_filling":
                mt5.ORDER_FILLING_IOC,
        }

        result = mt5.order_send(
            request
        )

        return {
            "needed": True,
            "retcode":
                getattr(
                    result,
                    "retcode",
                    None,
                ),
            "comment":
                getattr(
                    result,
                    "comment",
                    None,
                ),
        }

    finally:
        mt5.shutdown()


if (
    not gw_settings.api_token
    or gw_settings.api_token.startswith(
        "CHANGE_ME"
    )
):
    fail("MT5 API token not configured")

headers = {
    "Authorization":
        f"Bearer {gw_settings.api_token}"
}

save()

error = None
cleanup = None


with httpx.Client() as client:

    try:
        # --------------------------------------------------------
        # CORE / BRIDGE SAFETY
        # --------------------------------------------------------

        checkpoint("core_health:start")

        core_r = httpx.get(
            CORE + "/health",
            timeout=15.0,
        )

        core_r.raise_for_status()
        core_health = core_r.json()

        checkpoint(
            "core_health:ok",
            {
                "execution_enabled":
                    core_health.get(
                        "execution_enabled"
                    )
            },
        )

        if (
            core_health.get(
                "execution_enabled"
            )
            is not False
        ):
            fail(
                "Core execution must remain FALSE"
            )

        bridge_r = call(
            client,
            "bridge_health",
            "GET",
            "/health",
        )

        bridge_r.raise_for_status()
        bridge_health = bridge_r.json()

        if (
            bridge_health.get(
                "mt5_connected"
            )
            is not True
        ):
            fail(
                "MT5 not connected"
            )

        if (
            bridge_health.get(
                "live_trading"
            )
            is not True
        ):
            fail(
                "Temporary MT5 live trading "
                "is not enabled"
            )

        if (
            bridge_health.get(
                "management_enabled"
            )
            is not True
        ):
            fail(
                "Temporary management "
                "is not enabled"
            )

        # --------------------------------------------------------
        # DEMO ACCOUNT
        # --------------------------------------------------------

        r = call(
            client,
            "account",
            "GET",
            "/v1/account",
        )

        r.raise_for_status()

        account = AccountState(
            **r.json()
        )

        checkpoint(
            "account:parsed",
            {
                "login":
                    account.login,
                "server":
                    account.server,
                "equity":
                    account.equity,
            },
        )

        if "DEMO" not in (
            account.server or ""
        ).upper():
            fail(
                "Connected account is not DEMO"
            )

        account.license_active = (
            TradingService
            ._platform_license_for_login(
                account.login
            )
        )

        if not account.license_active:
            fail(
                "Platform license inactive"
            )

        # --------------------------------------------------------
        # LIVE BTC HEARTBEAT
        # --------------------------------------------------------

        checkpoint(
            "btc_heartbeat:start"
        )

        if not mt5.initialize():
            fail(
                f"MT5 initialize failed: "
                f"{mt5.last_error()}"
            )

        mt5.symbol_select(
            SYMBOL,
            True,
        )

        tick1 = mt5.symbol_info_tick(
            SYMBOL
        )

        time.sleep(2)

        tick2 = mt5.symbol_info_tick(
            SYMBOL
        )

        mt5.shutdown()

        if (
            tick1 is None
            or tick2 is None
        ):
            fail(
                "BTCUSD tick unavailable"
            )

        heartbeat_ok = (
            int(tick2.time_msc)
            > int(tick1.time_msc)
            or float(tick2.bid)
            != float(tick1.bid)
            or float(tick2.ask)
            != float(tick1.ask)
        )

        checkpoint(
            "btc_heartbeat:result",
            {
                "active":
                    heartbeat_ok,
                "first":
                    int(
                        tick1.time_msc
                    ),
                "second":
                    int(
                        tick2.time_msc
                    ),
            },
        )

        if not heartbeat_ok:
            fail(
                "BTCUSD market is not updating"
            )

        # --------------------------------------------------------
        # CLEAN STARTING STATE
        # --------------------------------------------------------

        before = get_positions(
            client
        )

        existing = [
            p
            for p in before
            if owned(p)
        ]

        if existing:
            fail(
                "Existing Abutron position "
                "detected"
            )

        if btc_positions(before):
            fail(
                "BTCUSD must be flat"
            )

        # --------------------------------------------------------
        # LIVE BTC BROKER CONTRACT
        # --------------------------------------------------------

        r = call(
            client,
            "btc_context",
            "GET",
            f"/v1/context/{SYMBOL}",
        )

        r.raise_for_status()

        broker = BrokerContext(
            **r.json()
        )

        checkpoint(
            "broker_contract",
            broker.model_dump(
                mode="json"
            ),
        )

        if broker.volume_min <= 0:
            fail(
                "Invalid broker minimum volume"
            )

        if broker.volume_step <= 0:
            fail(
                "Invalid broker volume step"
            )

        # --------------------------------------------------------
        # RISK ENGINE
        # --------------------------------------------------------

        now = int(time.time())
        px = float(broker.bid)

        market = MarketBundle(
            primary=MarketSnapshot(
                symbol=SYMBOL,
                timeframe="M1",
                candles=[
                    Candle(
                        ts=now,
                        open=px,
                        high=px,
                        low=px,
                        close=px,
                        volume=1.0,
                    )
                ],
                spread_points=
                    broker.spread_points,
                received_ts=now,
            ),
            contexts={},
        )

        thesis = Thesis(
            symbol=SYMBOL,
            direction=Direction.BUY,
            confidence=99.0,
            score=1.0,
            valid=True,
            reason=
                "BTC_DEMO_LIFECYCLE_CERTIFICATION",
            regime="CERTIFICATION",
            evidence={
                "synthetic": True,
                "purpose":
                    "DEMO_LIFECYCLE",
            },
        )

        risk = RiskEngine().evaluate(
            thesis=thesis,
            account=account,
            broker=broker,
            market=market,
            tier=BotTier.FLIPPER,
        )

        checkpoint(
            "risk_engine",
            risk.model_dump(
                mode="json"
            ),
        )

        if not risk.approved:
            fail(
                "RiskEngine blocked BTC test: "
                + risk.reason
            )

        # --------------------------------------------------------
        # CAPITAL ENGINE
        # --------------------------------------------------------

        profile = profile_for(
            BotTier.FLIPPER
        )

        risk_target = min(
            account.equity
            * (
                profile.risk_pct
                / 100.0
            ),
            risk.max_risk_amount,
        )

        denom = (
            profile.sl_atr
            * broker.tick_value
            * broker.volume_min
        )

        if (
            risk_target <= 0
            or broker.tick_size <= 0
            or denom <= 0
        ):
            fail(
                "Invalid capital inputs"
            )

        cert_atr = (
            0.75
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
            metadata={
                "synthetic": True
            },
        )

        buy_plan = make_order_plan(
            thesis=thesis,
            features=features,
            account=account,
            broker=broker,
            risk=risk,
            bar_ts=now,
            tier=BotTier.FLIPPER,
        )

        if buy_plan is None:
            fail(
                "Capital Engine produced "
                "no BTC OrderPlan"
            )

        buy_plan = (
            buy_plan.model_copy(
                update={
                    "idempotency_key":
                        uuid.uuid4().hex
                }
            )
        )

        checkpoint(
            "capital_plan",
            buy_plan.model_dump(
                mode="json"
            ),
        )

        if (
            abs(
                buy_plan.volume
                - broker.volume_min
            )
            > 1e-12
        ):
            fail(
                "Certification order is not "
                "broker minimum volume"
            )

        # opposite plan
        sell_thesis = (
            thesis.model_copy(
                update={
                    "direction":
                        Direction.SELL
                }
            )
        )

        sell_plan = make_order_plan(
            thesis=sell_thesis,
            features=features,
            account=account,
            broker=broker,
            risk=risk,
            bar_ts=now + 1,
            tier=BotTier.FLIPPER,
        )

        if sell_plan is None:
            fail(
                "No opposite guard plan"
            )

        sell_plan = (
            sell_plan.model_copy(
                update={
                    "idempotency_key":
                        uuid.uuid4().hex
                }
            )
        )

        # --------------------------------------------------------
        # BROKER ORDER CHECK FIRST
        # --------------------------------------------------------

        r = call(
            client,
            "order_check",
            "POST",
            "/v1/order-check",
            json=buy_plan.model_dump(
                mode="json"
            ),
            timeout=45.0,
        )

        r.raise_for_status()

        order_check = r.json()

        checkpoint(
            "order_check:parsed",
            order_check,
        )

        if (
            order_check.get(
                "check_passed"
            )
            is not True
        ):
            fail(
                "BTC broker order_check rejected"
            )

        if (
            order_check.get(
                "order_sent"
            )
            is not False
        ):
            fail(
                "order-check unexpectedly "
                "sent an order"
            )

        # --------------------------------------------------------
        # OPEN ONE BTC DEMO POSITION
        # --------------------------------------------------------

        r = call(
            client,
            "order",
            "POST",
            "/v1/order",
            json=buy_plan.model_dump(
                mode="json"
            ),
            timeout=120.0,
        )

        r.raise_for_status()

        opened = r.json()

        checkpoint(
            "order:parsed",
            opened,
        )

        if not opened.get(
            "accepted"
        ):
            fail(
                "BTC demo order not accepted"
            )

        opened_ticket = int(
            opened.get(
                "position_ticket",
                0,
            )
            or 0
        )

        time.sleep(0.5)

        rows = get_positions(
            client
        )

        owned_btc = [
            p
            for p in btc_positions(rows)
            if owned(p)
        ]

        if len(owned_btc) != 1:
            fail(
                "Expected exactly one "
                "Abutron BTCUSD position"
            )

        if not opened_ticket:
            opened_ticket = int(
                owned_btc[0]["ticket"]
            )

        checkpoint(
            "position_open",
            {
                "ticket":
                    opened_ticket,
                "count":
                    len(owned_btc),
            },
        )

        # --------------------------------------------------------
        # IDEMPOTENCY
        # --------------------------------------------------------

        r = call(
            client,
            "duplicate",
            "POST",
            "/v1/order",
            json=buy_plan.model_dump(
                mode="json"
            ),
            timeout=30.0,
        )

        r.raise_for_status()

        duplicate = r.json()

        if (
            duplicate.get(
                "duplicate"
            )
            is not True
        ):
            fail(
                "Idempotency duplicate "
                "was not detected"
            )

        checkpoint(
            "duplicate:verified"
        )

        # --------------------------------------------------------
        # OPPOSITE POSITION GUARD
        # --------------------------------------------------------

        r = call(
            client,
            "opposite_guard",
            "POST",
            "/v1/order",
            json=sell_plan.model_dump(
                mode="json"
            ),
            timeout=30.0,
        )

        if r.status_code != 409:
            fail(
                "Opposite guard expected "
                f"409, got {r.status_code}: "
                f"{r.text}"
            )

        checkpoint(
            "opposite_guard:verified"
        )

        # --------------------------------------------------------
        # MANAGEMENT
        # --------------------------------------------------------

        r = call(
            client,
            "manage",
            "POST",
            "/v1/manage",
            timeout=45.0,
        )

        r.raise_for_status()

        management = r.json()

        if (
            management.get(
                "managed"
            )
            is not True
        ):
            fail(
                "Management endpoint failed"
            )

        checkpoint(
            "manage:parsed",
            management,
        )

        # Empty actions are valid when price
        # has not reached break-even/trailing thresholds.

        # --------------------------------------------------------
        # CLOSE
        # --------------------------------------------------------

        r = call(
            client,
            "close",
            "POST",
            f"/v1/close/{opened_ticket}",
            timeout=120.0,
        )

        r.raise_for_status()

        closed = r.json()

        checkpoint(
            "close:parsed",
            closed,
        )

        if (
            closed.get(
                "closed"
            )
            is not True
        ):
            fail(
                "BTC demo close failed"
            )

        for _ in range(20):
            if not ticket_exists(
                client,
                opened_ticket
            ):
                break

            time.sleep(0.25)

        if ticket_exists(
            client,
            opened_ticket
        ):
            fail(
                "BTC position remains "
                "after close"
            )

        # --------------------------------------------------------
        # GATEWAY HISTORY ENDPOINT
        # --------------------------------------------------------

        r = call(
            client,
            "gateway_history",
            "GET",
            "/v1/history",
            params={
                "days": 1
            },
            timeout=30.0,
        )

        r.raise_for_status()

        gateway_history = r.json()

        checkpoint(
            "gateway_history:ok",
            {
                "type":
                    type(
                        gateway_history
                    ).__name__,
                "count":
                    (
                        len(
                            gateway_history
                        )
                        if hasattr(
                            gateway_history,
                            "__len__",
                        )
                        else None
                    ),
            },
        )

        # --------------------------------------------------------
        # EXACT TERMINAL HISTORY RECONCILIATION
        # --------------------------------------------------------

        open_deal = int(
            opened.get(
                "deal",
                0,
            )
            or 0
        )

        close_deal = int(
            closed.get(
                "deal",
                0,
            )
            or 0
        )

        if (
            open_deal <= 0
            or close_deal <= 0
        ):
            fail(
                "Broker did not return both "
                "deal identifiers"
            )

        if not mt5.initialize():
            fail(
                "Could not initialize MT5 "
                "for history reconciliation"
            )

        try:
            start = (
                datetime.now()
                - timedelta(days=7)
            )

            end = (
                datetime.now()
                + timedelta(hours=1)
            )

            deals = (
                mt5.history_deals_get(
                    start,
                    end,
                )
                or []
            )

            deal_ids = {
                int(d.ticket)
                for d in deals
            }

        finally:
            mt5.shutdown()

        open_reconciled = (
            open_deal in deal_ids
        )

        close_reconciled = (
            close_deal in deal_ids
        )

        checkpoint(
            "terminal_history",
            {
                "open_deal":
                    open_deal,

                "close_deal":
                    close_deal,

                "open_reconciled":
                    open_reconciled,

                "close_reconciled":
                    close_reconciled,
            },
        )

        if not open_reconciled:
            fail(
                "Opening deal missing "
                "from MT5 history"
            )

        if not close_reconciled:
            fail(
                "Closing deal missing "
                "from MT5 history"
            )

        final_positions = (
            get_positions(
                client
            )
        )

        final_owned = [
            p
            for p in final_positions
            if owned(p)
        ]

        if final_owned:
            fail(
                "Abutron position remains "
                "after certification"
            )

        evidence.update({
            "status":
                "PASS",

            "completed_utc":
                datetime.now(
                    timezone.utc
                ).isoformat(),

            "account": {
                "login":
                    account.login,
                "server":
                    account.server,
                "equity":
                    account.equity,
            },

            "broker":
                broker.model_dump(
                    mode="json"
                ),

            "risk":
                risk.model_dump(
                    mode="json"
                ),

            "plan":
                buy_plan.model_dump(
                    mode="json"
                ),

            "order_check":
                order_check,

            "open":
                opened,

            "duplicate":
                duplicate,

            "management":
                management,

            "management_action_observed":
                bool(
                    management.get(
                        "actions"
                    )
                ),

            "close":
                closed,

            "history": {
                "open_deal":
                    open_deal,

                "close_deal":
                    close_deal,

                "open_reconciled":
                    open_reconciled,

                "close_reconciled":
                    close_reconciled,
            },

            "positions_final":
                final_positions,
        })

        save()

    except Exception as exc:
        error = exc

        checkpoint(
            "FAILED",
            repr(exc),
        )

        evidence["status"] = (
            "FAILED"
        )

        evidence["error"] = (
            repr(exc)
        )

        # First try guarded gateway close.
        if opened_ticket:
            try:
                checkpoint(
                    "cleanup_gateway:start"
                )

                rr = client.post(
                    BASE
                    + "/v1/close/"
                    + str(
                        opened_ticket
                    ),
                    headers=headers,
                    timeout=60.0,
                )

                cleanup = {
                    "gateway_status":
                        rr.status_code,

                    "gateway_response":
                        (
                            rr.json()
                            if rr.content
                            else {}
                        ),
                }

                checkpoint(
                    "cleanup_gateway:end",
                    cleanup,
                )

            except Exception as cexc:
                cleanup = {
                    "gateway_error":
                        repr(cexc)
                }

        # Independent DEMO-only fallback.
        try:
            direct = (
                direct_demo_cleanup(
                    opened_ticket
                )
            )

            if cleanup is None:
                cleanup = {}

            cleanup[
                "direct_cleanup"
            ] = direct

            checkpoint(
                "cleanup_direct",
                direct,
            )

        except Exception as dexc:
            if cleanup is None:
                cleanup = {}

            cleanup[
                "direct_cleanup_error"
            ] = repr(dexc)

        evidence[
            "emergency_cleanup"
        ] = cleanup

        save()


print(
    json.dumps(
        evidence,
        indent=2,
        default=str,
    )
)

print(
    f"\nEVIDENCE_FILE={outfile}"
)

if error is not None:
    raise SystemExit(
        f"\nCERTIFICATION FAILED: "
        f"{error}"
    )

print(
    "\nBTCUSD FLIPPER DEMO LIFECYCLE PASS: "
    "order-check -> open -> idempotency -> "
    "opposite guard -> manage -> close -> "
    "terminal history reconciliation"
)