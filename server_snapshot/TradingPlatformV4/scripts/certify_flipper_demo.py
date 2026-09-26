from __future__ import annotations

import json
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx

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
SYMBOL = "XAUUSD"


def fail(message: str):
    raise RuntimeError(message)


if (
    not gw_settings.api_token
    or gw_settings.api_token.startswith("CHANGE_ME")
):
    fail("MT5 API token is not configured")


headers = {
    "Authorization": f"Bearer {gw_settings.api_token}"
}


def get_positions(client):
    r = client.get(
        f"{BASE}/v1/positions",
        headers=headers
    )
    r.raise_for_status()
    return r.json()


def is_abutron_position(p):
    return (
        int(p.get("magic", 0) or 0) == gw_settings.magic
        or str(p.get("comment", "")).upper().startswith("ABUTRON")
    )


def xau_positions(rows):
    return [
        p for p in rows
        if str(p.get("symbol", "")).upper().startswith("XAUUSD")
    ]


def ticket_exists(client, ticket):
    return any(
        int(p.get("ticket", 0)) == int(ticket)
        for p in get_positions(client)
    )


evidence = {
    "certification": "ABUTRON_V4_FLIPPER_DEMO_LIFECYCLE",
    "timestamp_utc": datetime.now(
        timezone.utc
    ).isoformat(),
    "status": "STARTED",
}

opened_ticket = 0
cleanup = None
error = None


with httpx.Client(timeout=30.0) as client:

    try:
        # --------------------------------------------------------
        # SAFETY PRECONDITIONS
        # --------------------------------------------------------

        core_health = client.get(
            f"{CORE}/health"
        ).json()

        bridge_health = client.get(
            f"{BASE}/health"
        ).json()

        if core_health.get("execution_enabled") is not False:
            fail(
                "ABUTRON Core execution must remain FALSE"
            )

        if bridge_health.get("mt5_connected") is not True:
            fail("MT5 gateway is not connected")

        if bridge_health.get("live_trading") is not True:
            fail(
                "Temporary MT5_LIVE_TRADING must be TRUE"
            )

        if bridge_health.get(
            "management_enabled"
        ) is not True:
            fail(
                "Temporary MT5_MANAGEMENT_ENABLED must be TRUE"
            )

        r = client.get(
            f"{BASE}/v1/account",
            headers=headers
        )
        r.raise_for_status()

        account = AccountState(**r.json())

        if "DEMO" not in account.server.upper():
            fail(
                f"Execution blocked: server is not DEMO: "
                f"{account.server}"
            )

        account.license_active = (
            TradingService._platform_license_for_login(
                account.login
            )
        )

        if not account.license_active:
            fail(
                "Platform license is not active"
            )

        before = get_positions(client)

        if xau_positions(before):
            fail(
                "XAUUSD must be flat before certification"
            )

        existing_abutron = [
            p for p in before
            if is_abutron_position(p)
        ]

        if existing_abutron:
            fail(
                "Existing Abutron position detected; "
                "certification requires a clean starting state"
            )

        # --------------------------------------------------------
        # LIVE BROKER CONTEXT
        # --------------------------------------------------------

        r = client.get(
            f"{BASE}/v1/context/{SYMBOL}",
            headers=headers
        )
        r.raise_for_status()

        broker = BrokerContext(**r.json())

        if abs(
            broker.volume_min - 0.01
        ) > 1e-12:
            fail(
                f"Unexpected minimum lot: "
                f"{broker.volume_min}"
            )

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
                spread_points=broker.spread_points,
                received_ts=now,
            ),
            contexts={},
        )

        # --------------------------------------------------------
        # SYNTHETIC CERTIFICATION THESIS
        # Not a real market signal.
        # --------------------------------------------------------

        buy_thesis = Thesis(
            symbol=SYMBOL,
            direction=Direction.BUY,
            confidence=99.0,
            score=1.0,
            valid=True,
            reason="DEMO_LIFECYCLE_CERTIFICATION",
            regime="CERTIFICATION",
            evidence={
                "synthetic": True,
                "purpose": "DEMO_ORDER_LIFECYCLE",
            },
        )

        risk = RiskEngine().evaluate(
            thesis=buy_thesis,
            account=account,
            broker=broker,
            market=market,
            tier=BotTier.FLIPPER,
        )

        if not risk.approved:
            fail(
                f"RiskEngine blocked demo certification: "
                f"{risk.reason}"
            )

        profile = profile_for(
            BotTier.FLIPPER
        )

        risk_target = min(
            account.equity
            * (profile.risk_pct / 100.0),
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
                "Invalid risk/broker inputs"
            )

        # 75% of available risk budget ensures
        # capital floors to minimum broker lot = 0.01.
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
            thesis=buy_thesis,
            features=features,
            account=account,
            broker=broker,
            risk=risk,
            bar_ts=now,
            tier=BotTier.FLIPPER,
        )

        if buy_plan is None:
            fail(
                "Capital engine returned no BUY plan"
            )

        buy_plan = buy_plan.model_copy(
            update={
                "idempotency_key":
                    uuid.uuid4().hex
            }
        )

        if abs(
            buy_plan.volume - broker.volume_min
        ) > 1e-12:
            fail(
                "Certification volume is not "
                f"minimum lot: {buy_plan.volume}"
            )

        if buy_plan.risk_amount > risk_target + 1e-9:
            fail(
                "Capital plan exceeds strategy risk target"
            )

        # Prepare opposite plan BEFORE opening BUY.
        sell_thesis = buy_thesis.model_copy(
            update={
                "direction": Direction.SELL
            }
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
                "Capital engine returned no SELL guard plan"
            )

        sell_plan = sell_plan.model_copy(
            update={
                "idempotency_key":
                    uuid.uuid4().hex
            }
        )

        # --------------------------------------------------------
        # OPEN ONE REAL DEMO POSITION
        # --------------------------------------------------------

        r = client.post(
            f"{BASE}/v1/order",
            headers=headers,
            json=buy_plan.model_dump(
                mode="json"
            ),
        )

        r.raise_for_status()
        opened = r.json()

        if not opened.get("accepted"):
            fail(
                f"Broker did not accept demo order: "
                f"{opened}"
            )

        time.sleep(0.75)

        after_open = get_positions(client)

        owned_xau = [
            p for p in xau_positions(after_open)
            if is_abutron_position(p)
        ]

        if len(owned_xau) != 1:
            fail(
                "Expected exactly one Abutron "
                "XAUUSD position after open"
            )

        opened_ticket = int(
            opened.get(
                "position_ticket",
                0
            )
            or owned_xau[0]["ticket"]
        )

        if not opened_ticket:
            fail(
                "Could not identify opened position ticket"
            )

        if not ticket_exists(
            client,
            opened_ticket
        ):
            fail(
                "Opened ticket not found in positions"
            )

        # --------------------------------------------------------
        # IDEMPOTENCY
        # --------------------------------------------------------

        r = client.post(
            f"{BASE}/v1/order",
            headers=headers,
            json=buy_plan.model_dump(
                mode="json"
            ),
        )

        r.raise_for_status()
        duplicate = r.json()

        if duplicate.get(
            "duplicate"
        ) is not True:
            fail(
                "Duplicate order was not detected"
            )

        after_duplicate = get_positions(
            client
        )

        owned_after_duplicate = [
            p for p in xau_positions(
                after_duplicate
            )
            if is_abutron_position(p)
        ]

        if len(
            owned_after_duplicate
        ) != 1:
            fail(
                "Duplicate request changed position count"
            )

        # --------------------------------------------------------
        # OPPOSITE POSITION GUARD
        # --------------------------------------------------------

        opposite = client.post(
            f"{BASE}/v1/order",
            headers=headers,
            json=sell_plan.model_dump(
                mode="json"
            ),
        )

        if opposite.status_code != 409:
            fail(
                "Opposite-position guard did not "
                f"return HTTP 409; got "
                f"{opposite.status_code}: "
                f"{opposite.text}"
            )

        if len([
            p for p in xau_positions(
                get_positions(client)
            )
            if is_abutron_position(p)
        ]) != 1:
            fail(
                "Opposite order changed position count"
            )

        # --------------------------------------------------------
        # MANAGEMENT CYCLE
        # --------------------------------------------------------

        r = client.post(
            f"{BASE}/v1/manage",
            headers=headers,
        )

        r.raise_for_status()
        management = r.json()

        if management.get(
            "managed"
        ) is not True:
            fail(
                f"Management endpoint failed: "
                f"{management}"
            )

        relevant_actions = [
            a for a in management.get(
                "actions", []
            )
            if int(
                a.get("ticket", 0)
            ) == opened_ticket
        ]

        for action in relevant_actions:
            if not action.get("ok"):
                fail(
                    "Management attempted an "
                    "unsuccessful SL modification"
                )

            if (
                float(action["new_sl"])
                <= float(action["old_sl"])
            ):
                fail(
                    "BUY management worsened or "
                    "failed to improve SL"
                )

        # --------------------------------------------------------
        # CLOSE THROUGH ABUTRON API
        # --------------------------------------------------------

        r = client.post(
            f"{BASE}/v1/close/{opened_ticket}",
            headers=headers,
        )

        r.raise_for_status()
        closed = r.json()

        if closed.get(
            "closed"
        ) is not True:
            fail(
                f"Close endpoint failed: "
                f"{closed}"
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
                "Position still exists after close"
            )

        # --------------------------------------------------------
        # BROKER HISTORY RECONCILIATION
        # --------------------------------------------------------

        open_deal = int(
            opened.get("deal", 0) or 0
        )

        close_deal = int(
            closed.get("deal", 0) or 0
        )

        history = []

        for _ in range(20):
            r = client.get(
                f"{BASE}/v1/history",
                params={"days": 1},
                headers=headers,
            )
            r.raise_for_status()
            history = r.json()

            ids = {
                int(x.get("ticket", 0))
                for x in history
            }

            open_ok = (
                open_deal > 0
                and open_deal in ids
            )

            close_ok = (
                close_deal > 0
                and close_deal in ids
            )

            if open_ok and close_ok:
                break

            time.sleep(0.25)

        ids = {
            int(x.get("ticket", 0))
            for x in history
        }

        open_history_ok = (
            open_deal > 0
            and open_deal in ids
        )

        close_history_ok = (
            close_deal > 0
            and close_deal in ids
        )

        if not open_history_ok:
            fail(
                "Opening broker deal was not "
                "reconciled in history"
            )

        if not close_history_ok:
            fail(
                "Closing broker deal was not "
                "reconciled in history"
            )

        final_positions = get_positions(
            client
        )

        final_abutron = [
            p for p in final_positions
            if is_abutron_position(p)
        ]

        if final_abutron:
            fail(
                "Abutron position remains after lifecycle"
            )

        evidence.update({
            "status": "PASS",

            "safety": {
                "core_execution_enabled":
                    core_health.get(
                        "execution_enabled"
                    ),

                "demo_server":
                    account.server,

                "mt5_live_trading":
                    bridge_health.get(
                        "live_trading"
                    ),

                "management_enabled":
                    bridge_health.get(
                        "management_enabled"
                    ),

                "demo_only":
                    gw_settings.demo_only,
            },

            "account": {
                "login":
                    account.login,
                "server":
                    account.server,
                "equity":
                    account.equity,
                "license_active":
                    account.license_active,
            },

            "risk":
                risk.model_dump(
                    mode="json"
                ),

            "risk_target":
                risk_target,

            "plan":
                buy_plan.model_dump(
                    mode="json"
                ),

            "open":
                opened,

            "duplicate":
                duplicate,

            "opposite_guard": {
                "status_code":
                    opposite.status_code,
                "response":
                    opposite.json(),
            },

            "management":
                management,

            "management_action_observed":
                bool(relevant_actions),

            "close":
                closed,

            "history": {
                "open_deal":
                    open_deal,
                "close_deal":
                    close_deal,
                "open_reconciled":
                    open_history_ok,
                "close_reconciled":
                    close_history_ok,
            },

            "positions_before":
                before,

            "positions_final":
                final_positions,
        })

    except Exception as exc:
        error = exc

    finally:
        # Emergency cleanup if anything failed
        # after opening the demo position.
        if (
            opened_ticket
            and ticket_exists(
                client,
                opened_ticket
            )
        ):
            try:
                rr = client.post(
                    f"{BASE}/v1/close/"
                    f"{opened_ticket}",
                    headers=headers,
                )

                cleanup = {
                    "status_code":
                        rr.status_code,
                    "response":
                        (
                            rr.json()
                            if rr.content
                            else {}
                        ),
                }

            except Exception as cleanup_exc:
                cleanup = {
                    "error":
                        repr(cleanup_exc)
                }

        if error is not None:
            evidence["status"] = "FAILED"
            evidence["error"] = repr(error)
            evidence["emergency_cleanup"] = cleanup


logs = ROOT / "logs"
logs.mkdir(
    parents=True,
    exist_ok=True
)

outfile = logs / (
    "flipper-demo-lifecycle-"
    + datetime.now().strftime(
        "%Y%m%d-%H%M%S"
    )
    + ".json"
)

outfile.write_text(
    json.dumps(
        evidence,
        indent=2,
        default=str
    ),
    encoding="utf-8",
)

print(
    json.dumps(
        evidence,
        indent=2,
        default=str
    )
)

print(
    f"\nEVIDENCE_FILE={outfile}"
)

if error is not None:
    raise SystemExit(
        f"\nCERTIFICATION FAILED: {error}"
    )

print(
    "\nFLIPPER DEMO LIFECYCLE PASS: "
    "open -> duplicate guard -> "
    "opposite guard -> manage -> "
    "close -> history reconciliation"
)