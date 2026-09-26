from __future__ import annotations

import argparse
import inspect
import json
import shutil
import sqlite3
import sys
import tempfile
import time
import uuid
from pathlib import Path
from types import SimpleNamespace

from fastapi import HTTPException
from pydantic import ValidationError

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as native_mt5

from abutron.models import BotTier, Direction, OrderPlan
from mt5_bridge.settings import settings as bridge_settings
from mt5_bridge.store import IdempotencyStore
import mt5_bridge.app as gateway


class OrderSendTripwire(RuntimeError):
    pass


class MT5Proxy:
    """
    Delegates to the real MetaTrader5 module except for functions explicitly
    overridden by Step 16. No native order_send call is ever permitted.
    """

    def __init__(self, real_module):
        self._real = real_module
        self.order_send_attempts = 0
        self.native_order_send_calls = 0

        self._account_info_override = None
        self._order_check_override = None
        self._positions_get_override = None

    def __getattr__(self, name):
        return getattr(self._real, name)

    def account_info(self):
        if self._account_info_override is not None:
            return self._account_info_override()
        return self._real.account_info()

    def order_check(self, request):
        if self._order_check_override is not None:
            return self._order_check_override(request)
        return self._real.order_check(request)

    def positions_get(self, *args, **kwargs):
        if self._positions_get_override is not None:
            return self._positions_get_override(*args, **kwargs)
        return self._real.positions_get(*args, **kwargs)

    def order_send(self, request):
        self.order_send_attempts += 1
        # Critical: DO NOT delegate to self._real.order_send.
        raise OrderSendTripwire("STEP16_ORDER_SEND_BOUNDARY_BLOCKED")


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def http_detail_text(exc: HTTPException) -> str:
    return str(exc.detail)


def expect_http_exception(fn, status: int, contains: str | None = None) -> HTTPException:
    try:
        fn()
    except HTTPException as exc:
        require(
            exc.status_code == status,
            f"Expected HTTP {status}, got HTTP {exc.status_code}: {exc.detail}",
        )
        if contains:
            require(
                contains.upper() in http_detail_text(exc).upper(),
                f"Expected error containing {contains!r}, got: {exc.detail}",
            )
        return exc
    raise RuntimeError(f"Expected HTTP {status}, but call succeeded.")


def source_segment(text: str, start_marker: str, end_marker: str) -> str:
    start = text.find(start_marker)
    end = text.find(end_marker, start + len(start_marker))
    require(start >= 0, f"Source marker missing: {start_marker}")
    require(end > start, f"Source end marker missing after {start_marker}: {end_marker}")
    return text[start:end]


def static_source_audit() -> None:
    app_path = ROOT / "mt5_bridge" / "app.py"
    store_path = ROOT / "mt5_bridge" / "store.py"

    app_source = app_path.read_text(encoding="utf-8-sig")
    store_source = store_path.read_text(encoding="utf-8-sig")

    order_check_src = source_segment(
        app_source,
        '@app.post("/v1/order-check")',
        '@app.post("/v1/order")',
    )
    order_src = source_segment(
        app_source,
        '@app.post("/v1/order")',
        '@app.post("/v1/manage")',
    )
    manage_src = source_segment(
        app_source,
        '@app.post("/v1/manage")',
        '@app.post("/v1/close/{ticket}")',
    )

    close_start = app_source.find('@app.post("/v1/close/{ticket}")')
    require(close_start >= 0, "Close endpoint source missing.")
    close_src = app_source[close_start:]

    guard_src = source_segment(
        app_source,
        "def _require_demo_if_configured():",
        "def _is_abutron_position",
    )

    require("order_send(" not in order_check_src, "/v1/order-check contains order_send().")
    require("_build_order_request" in order_check_src, "/v1/order-check does not build real request.")
    require("order_check(" in order_check_src, "/v1/order-check does not call broker order_check.")

    for token in (
        "store.claim",
        "IDEMPOTENCY_IN_PROGRESS",
        "MT5_LIVE_TRADING_FALSE",
        "_require_demo_if_configured",
        "_build_order_request",
        "order_check",
        "ORDER_CHECK_REJECTED",
        "send_attempted=True",
        "order_send",
    ):
        require(token in order_src, f"Order safety token missing: {token}")

    require(
        order_src.find("store.claim") < order_src.find("order_send"),
        "Atomic claim does not precede broker send.",
    )
    require(
        order_src.find("MT5_LIVE_TRADING_FALSE") < order_src.find("order_send"),
        "Live-trading guard does not precede broker send.",
    )
    require(
        order_src.find("_require_demo_if_configured") < order_src.find("order_send"),
        "Demo/account guard does not precede broker send.",
    )
    require(
        order_src.find("order_check") < order_src.find("order_send"),
        "Broker order_check does not precede broker send.",
    )
    require(
        order_src.find("send_attempted=True") < order_src.find("order_send"),
        "send_attempted fail-closed marker does not precede broker send.",
    )

    require("management_enabled" in manage_src, "Management refusal guard missing.")
    require("order_send" in manage_src, "Management mutation boundary missing.")
    require(
        manage_src.find("management_enabled") < manage_src.find("order_send"),
        "Management refusal guard is after mutation boundary.",
    )

    require("live_trading" in close_src, "Close live-trading refusal guard missing.")
    require("order_send" in close_src, "Close mutation boundary missing.")
    require(
        close_src.find("live_trading") < close_src.find("order_send"),
        "Close refusal guard is after mutation boundary.",
    )
    require(
        "_is_abutron_position" in close_src,
        "Close endpoint ownership enforcement missing.",
    )

    for token in ("demo_only", "expected_login", "expected_server"):
        require(token in guard_src, f"Execution identity guard missing: {token}")

    for token in ("execution_claims", "def claim(", "def release_claim(", "def claim_exists("):
        require(token in store_source, f"Idempotency hardening missing: {token}")

    emit("STATIC_EXECUTION_GATEWAY_AUDIT", "PASS")
    emit("ORDER_CHECK_ROUTE_HAS_ORDER_SEND", False)
    emit("ATOMIC_CLAIM_SOURCE_GUARD", "PASS")
    emit("ORDER_CHECK_BEFORE_SEND_SOURCE_GUARD", "PASS")
    emit("MANAGE_GUARD_BEFORE_SEND", "PASS")
    emit("CLOSE_GUARD_BEFORE_SEND", "PASS")


def snapshot_mt5(start_epoch: int):
    account = native_mt5.account_info()
    terminal = native_mt5.terminal_info()

    require(account is not None, "MT5 account_info unavailable.")
    require(terminal is not None and bool(terminal.connected), "MT5 terminal is not connected.")

    positions = native_mt5.positions_get()
    require(positions is not None, "MT5 positions_get failed.")

    all_tickets = sorted(int(p.ticket) for p in positions)
    magic = int(bridge_settings.magic)
    magic_positions = sorted(
        int(p.ticket)
        for p in positions
        if int(getattr(p, "magic", 0) or 0) == magic
    )

    from datetime import datetime, timezone

    deals = native_mt5.history_deals_get(
        datetime.fromtimestamp(start_epoch, tz=timezone.utc),
        datetime.now(timezone.utc),
    )
    require(deals is not None, "MT5 history_deals_get failed.")

    magic_deals = [
        d
        for d in deals
        if int(getattr(d, "magic", 0) or 0) == magic
    ]

    return {
        "server": str(getattr(account, "server", "") or ""),
        "login": int(getattr(account, "login", 0) or 0),
        "trade_allowed": bool(getattr(terminal, "trade_allowed", False)),
        "all_tickets": all_tickets,
        "magic_positions": magic_positions,
        "magic_deals": len(magic_deals),
    }


def make_valid_plan(proxy: MT5Proxy, key: str, symbol: str) -> OrderPlan:
    raw = gateway.raw_symbol(symbol)
    tick = proxy.symbol_info_tick(raw)
    info = proxy.symbol_info(raw)

    require(tick is not None, "No live tick for certification symbol.")
    require(info is not None, "No symbol_info for certification symbol.")

    volume_min = float(info.volume_min)
    volume_step = float(info.volume_step)
    point = float(info.point or 0.0)
    tick_size = float(info.trade_tick_size or point or 0.01)
    stops_level = int(info.trade_stops_level or 0)

    require(volume_min > 0.0, "Broker volume_min is not positive.")
    require(volume_step > 0.0, "Broker volume_step is not positive.")
    require(float(tick.ask) > 0.0, "Broker ask price is invalid.")

    distance = max(
        tick_size * 100.0,
        point * float(max(stops_level + 20, 100)),
        1.0,
    )

    entry = float(tick.ask)
    sl = entry - distance
    tp = entry + (2.0 * distance)

    return OrderPlan(
        symbol=symbol,
        direction=Direction.BUY,
        tier=BotTier.FLIPPER,
        strategy_profile="step16-certification",
        volume=volume_min,
        entry=entry,
        sl=sl,
        tp=tp,
        risk_amount=0.01,
        confidence=99.0,
        idempotency_key=key,
        thesis_reason="STEP16_CERTIFICATION_ONLY",
    )


def schema_refusal_tests(valid_payload: dict) -> None:
    cases = []

    missing = dict(valid_payload)
    missing.pop("idempotency_key", None)
    cases.append(("missing_required_field", missing))

    bad_direction = dict(valid_payload)
    bad_direction["direction"] = "STEP16_INVALID_DIRECTION"
    cases.append(("invalid_direction", bad_direction))

    bad_tier = dict(valid_payload)
    bad_tier["tier"] = "STEP16_INVALID_TIER"
    cases.append(("invalid_tier", bad_tier))

    for name, payload in cases:
        try:
            OrderPlan(**payload)
        except ValidationError:
            continue
        raise RuntimeError(f"OrderPlan schema did not reject case: {name}")

    emit("ORDERPLAN_SCHEMA_REFUSAL", "PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mt5-path", required=True)
    parser.add_argument("--symbol", default="XAUUSD")
    args = parser.parse_args()

    stamp = f"{int(time.time())}-{uuid.uuid4().hex[:10]}"
    prefix = f"STEP16-{stamp}"
    start_epoch = int(time.time())

    temp_dir = Path(tempfile.mkdtemp(prefix="abutron-step16-", dir=str(ROOT / "logs")))
    temp_db = temp_dir / "step16_idempotency.sqlite3"

    original_store = gateway.store
    original_db_path = str(bridge_settings.idempotency_db)
    original_live = bool(bridge_settings.live_trading)
    original_management = bool(bridge_settings.management_enabled)
    original_mt5 = gateway.mt5

    proxy = MT5Proxy(native_mt5)
    tested_keys: list[str] = []

    native_initialized = False

    try:
        emit("STEP16_PREFIX_CREATED", True)

        static_source_audit()

        require(original_live is False, "Production MT5 live_trading must be false before Step 16.")
        require(original_management is False, "Production management must be false before Step 16.")
        require(bool(bridge_settings.demo_only) is True, "MT5 demo_only must be true.")
        require(bridge_settings.expected_login is not None, "Expected MT5 login is not configured.")
        require(
            bool(str(bridge_settings.expected_server or "").strip()),
            "Expected MT5 server is not configured.",
        )

        if not native_mt5.initialize(path=args.mt5_path):
            raise RuntimeError(f"MT5 initialize failed: {native_mt5.last_error()}")
        native_initialized = True

        before = snapshot_mt5(start_epoch)

        require(
            before["login"] == int(bridge_settings.expected_login),
            "Connected MT5 login does not match configured expected login.",
        )
        require(
            before["server"] == str(bridge_settings.expected_server),
            "Connected MT5 server does not match configured expected server.",
        )
        require(
            "DEMO" in before["server"].upper(),
            "Connected MT5 server is not a demo server.",
        )

        emit("MT5_BASELINE", "PASS")
        emit("MT5_TERMINAL_TRADE_ALLOWED", before["trade_allowed"])
        emit("MT5_MAGIC_POSITIONS_BASELINE", len(before["magic_positions"]))

        # ------------------------------------------------------------------
        # Isolate Step 16 persistence from production.
        # IdempotencyStore.db() resolves settings.idempotency_db dynamically,
        # so the setting must stay pointed at the temp DB during the test.
        # ------------------------------------------------------------------
        bridge_settings.idempotency_db = str(temp_db)
        gateway.settings.idempotency_db = str(temp_db)
        cert_store = IdempotencyStore()
        gateway.store = cert_store
        gateway.mt5 = proxy

        emit("TEMP_IDEMPOTENCY_STORE", "PASS")

        # ------------------------------------------------------------------
        # Authentication refusal.
        # ------------------------------------------------------------------
        expect_http_exception(lambda: gateway.auth(None), 401, "Unauthorized")
        expect_http_exception(
            lambda: gateway.auth("Bearer STEP16_INVALID_TOKEN"),
            401,
            "Unauthorized",
        )

        valid_auth = f"Bearer {bridge_settings.api_token}"
        gateway.auth(valid_auth)
        emit("AUTH_REFUSAL", "PASS")
        emit("VALID_AUTH_ACCEPTED", "PASS")
        emit("API_TOKEN_PRINTED", False)

        # ------------------------------------------------------------------
        # Real account identity guard + deterministic negative variants.
        # ------------------------------------------------------------------
        gateway._require_demo_if_configured()
        emit("REAL_DEMO_ACCOUNT_GUARD", "PASS")

        expected_login = int(bridge_settings.expected_login)
        expected_server = str(bridge_settings.expected_server)

        real_account_info = proxy._account_info_override

        proxy._account_info_override = lambda: SimpleNamespace(
            login=expected_login,
            server="STEP16-LIVE",
        )
        expect_http_exception(
            gateway._require_demo_if_configured,
            403,
            "DEMO",
        )
        emit("DEMO_ACCOUNT_GUARD", "PASS")

        proxy._account_info_override = lambda: SimpleNamespace(
            login=expected_login + 1,
            server=expected_server,
        )
        expect_http_exception(
            gateway._require_demo_if_configured,
            403,
            "EXPECTED_LOGIN",
        )
        emit("EXPECTED_LOGIN_GUARD", "PASS")

        wrong_demo_server = "STEP16-WRONG-DEMO"
        if wrong_demo_server == expected_server:
            wrong_demo_server = "STEP16-OTHER-DEMO"

        proxy._account_info_override = lambda: SimpleNamespace(
            login=expected_login,
            server=wrong_demo_server,
        )
        expect_http_exception(
            gateway._require_demo_if_configured,
            403,
            "EXPECTED_SERVER",
        )
        emit("EXPECTED_SERVER_GUARD", "PASS")

        proxy._account_info_override = real_account_info

        # ------------------------------------------------------------------
        # Build a valid payload from current broker metadata.
        # ------------------------------------------------------------------
        base_key = f"{prefix}-DRY"
        tested_keys.append(base_key)
        valid_plan = make_valid_plan(proxy, base_key, args.symbol)
        valid_payload = valid_plan.model_dump(mode="json")

        schema_refusal_tests(valid_payload)

        # Ignore unrelated positions while exercising request construction.
        # This does NOT alter MT5; it only isolates payload validation.
        proxy._positions_get_override = lambda *a, **k: []

        raw_symbol, desired_buy, request, info = gateway._build_order_request(valid_plan)

        require(desired_buy is True, "Valid BUY plan was not mapped to BUY.")
        require(request["action"] == proxy.TRADE_ACTION_DEAL, "Wrong MT5 action.")
        require(request["symbol"] == raw_symbol, "Resolved symbol mismatch.")
        require(abs(float(request["volume"]) - float(valid_plan.volume)) < 1e-12, "Volume mismatch.")
        require(request["type"] == proxy.ORDER_TYPE_BUY, "Order type mismatch.")
        require(float(request["price"]) > 0.0, "Request price invalid.")
        require(float(request["sl"]) < float(request["price"]), "BUY SL is not below price.")
        require(float(request["tp"]) > float(request["price"]), "BUY TP is not above price.")
        require(int(request["magic"]) == int(bridge_settings.magic), "Magic mismatch.")
        require(str(request["comment"]).upper().startswith("ABUTRON"), "Comment ownership marker missing.")
        require(int(request["deviation"]) == int(bridge_settings.deviation_points), "Deviation mismatch.")
        require("type_time" in request, "Order time policy missing.")
        require("type_filling" in request, "Order filling policy missing.")

        emit("ORDER_REQUEST_PAYLOAD", "PASS")
        emit("BROKER_SYMBOL_RESOLUTION", "PASS")
        emit("BROKER_VOLUME_MIN_POSITIVE", float(info.volume_min) > 0.0)
        emit("BROKER_VOLUME_STEP_POSITIVE", float(info.volume_step) > 0.0)

        below_min = valid_plan.model_copy(
            update={
                "volume": max(0.0, float(info.volume_min) - max(float(info.volume_step), 0.01)),
                "idempotency_key": f"{prefix}-BELOWMIN",
            }
        )
        expect_http_exception(
            lambda: gateway._build_order_request(below_min),
            400,
            "minimum",
        )
        emit("BROKER_MIN_VOLUME_REFUSAL", "PASS")

        # ------------------------------------------------------------------
        # Real broker order_check-only path. This never calls order_send.
        # ------------------------------------------------------------------
        real_check_result = gateway.order_check_only(
            valid_plan,
            authorization=valid_auth,
        )

        require(real_check_result.get("checked") is True, "Real order_check path did not complete.")
        require(real_check_result.get("order_sent") is False, "order_check path claims an order was sent.")
        emit("BROKER_ORDER_CHECK_NO_SEND", "PASS")
        emit("BROKER_ORDER_CHECK_RETCODE", real_check_result.get("retcode"))
        emit("BROKER_ORDER_CHECK_PASSED", real_check_result.get("check_passed"))

        require(proxy.order_send_attempts == 0, "order_send boundary reached during order-check-only test.")

        # ------------------------------------------------------------------
        # Real /v1/order function logic with live_trading=False.
        # ------------------------------------------------------------------
        require(bridge_settings.live_trading is False, "Live trading changed before dry-run test.")

        dry = gateway.order(valid_plan, authorization=valid_auth)

        require(dry.get("accepted") is False, "Dry-run order unexpectedly accepted.")
        require(dry.get("mode") == "DRY_RUN", f"Unexpected dry-run mode: {dry}")
        require(
            dry.get("reason") == "MT5_LIVE_TRADING_FALSE",
            f"Unexpected dry-run reason: {dry}",
        )
        require(cert_store.get(base_key) is not None, "Dry-run result was not persisted.")
        require(not bool(cert_store.claim_exists(base_key)), "Dry-run claim was not released.")
        require(proxy.order_send_attempts == 0, "order_send boundary reached during dry-run refusal.")

        emit("DRY_RUN_REFUSAL", "PASS")
        emit("DRY_RUN_RESULT_PERSISTED", "PASS")

        duplicate = gateway.order(valid_plan, authorization=valid_auth)
        require(duplicate.get("duplicate") is True, "Completed duplicate was not returned as duplicate.")
        require(duplicate.get("mode") == "DRY_RUN", "Completed duplicate did not return stored result.")
        require(proxy.order_send_attempts == 0, "order_send boundary reached for completed duplicate.")
        emit("IDEMPOTENCY_COMPLETED_DUPLICATE", "PASS")

        # ------------------------------------------------------------------
        # In-progress duplicate claim.
        # ------------------------------------------------------------------
        inflight_key = f"{prefix}-INPROGRESS"
        tested_keys.append(inflight_key)
        inflight_plan = valid_plan.model_copy(update={"idempotency_key": inflight_key})

        require(cert_store.claim(inflight_key) is True, "Could not seed in-progress claim.")

        exc = expect_http_exception(
            lambda: gateway.order(inflight_plan, authorization=valid_auth),
            409,
            "IDEMPOTENCY_IN_PROGRESS",
        )
        require(
            "IDEMPOTENCY_IN_PROGRESS" in http_detail_text(exc),
            "Wrong in-progress idempotency response.",
        )
        require(proxy.order_send_attempts == 0, "order_send boundary reached for in-progress duplicate.")
        cert_store.release_claim(inflight_key)
        emit("IDEMPOTENCY_IN_PROGRESS", "PASS")

        # ------------------------------------------------------------------
        # Deterministic broker-check rejection while local live flag is true.
        # This is PROCESS-LOCAL ONLY. Production Bridge stays live_trading=False.
        # ------------------------------------------------------------------
        reject_key = f"{prefix}-CHECKREJECT"
        tested_keys.append(reject_key)
        reject_plan = valid_plan.model_copy(update={"idempotency_key": reject_key})

        bridge_settings.live_trading = True
        gateway.settings.live_trading = True

        proxy._order_check_override = lambda request: SimpleNamespace(
            retcode=10013,
            comment="STEP16_SYNTHETIC_ORDER_CHECK_REJECTION",
        )

        expect_http_exception(
            lambda: gateway.order(reject_plan, authorization=valid_auth),
            409,
            "ORDER_CHECK_REJECTED",
        )

        require(proxy.order_send_attempts == 0, "order_send boundary reached after rejected order_check.")

        stored_reject = cert_store.get(reject_key)
        require(stored_reject is not None, "Order-check rejection was not persisted.")
        require(
            stored_reject.get("mode") == "ORDER_CHECK_REJECTED",
            "Wrong persisted order-check rejection mode.",
        )
        require(
            not bool(cert_store.claim_exists(reject_key)),
            "Order-check rejection claim was not released.",
        )

        reject_duplicate = gateway.order(reject_plan, authorization=valid_auth)
        require(
            reject_duplicate.get("duplicate") is True,
            "Rejected execution duplicate was not returned from persistence.",
        )
        require(proxy.order_send_attempts == 0, "order_send boundary reached on rejected duplicate.")

        emit("ORDER_CHECK_REJECTION_NO_SEND", "PASS")
        emit("ORDER_CHECK_REJECTION_PERSISTED", "PASS")
        emit("REJECTED_REQUEST_DUPLICATE_SUPPRESSED", "PASS")

        # ------------------------------------------------------------------
        # Approved-to-send boundary. Fake order_check retcode=0, but replace
        # order_send with the hard tripwire. Native broker order_send remains 0.
        # ------------------------------------------------------------------
        boundary_key = f"{prefix}-BOUNDARY"
        tested_keys.append(boundary_key)
        boundary_plan = valid_plan.model_copy(update={"idempotency_key": boundary_key})

        proxy._order_check_override = lambda request: SimpleNamespace(
            retcode=0,
            comment="STEP16_SYNTHETIC_ORDER_CHECK_PASS",
        )

        caught = None
        try:
            gateway.order(boundary_plan, authorization=valid_auth)
        except BaseException as exc:
            caught = exc

        require(caught is not None, "Order-send boundary tripwire did not fire.")
        require(
            isinstance(caught, OrderSendTripwire),
            f"Unexpected exception at order-send boundary: {type(caught).__name__}: {caught}",
        )
        require(proxy.order_send_attempts == 1, "Order-send boundary attempt count is not exactly one.")
        require(
            bool(cert_store.claim_exists(boundary_key)),
            "Unresolved send claim did not remain fail-closed.",
        )
        require(
            cert_store.get(boundary_key) is None,
            "Synthetic unresolved send unexpectedly has a completed execution result.",
        )

        emit("ORDER_SEND_BOUNDARY_TRIPWIRE", "PASS")
        emit("UNRESOLVED_SEND_CLAIM_FAIL_CLOSED", "PASS")
        emit("NATIVE_ORDER_SEND_CALLS", proxy.native_order_send_calls)

        # Release the synthetic temp claim only after proving fail-closed state.
        cert_store.release_claim(boundary_key)

        # ------------------------------------------------------------------
        # Restore local live flag OFF before manage/close refusal.
        # ------------------------------------------------------------------
        bridge_settings.live_trading = False
        gateway.settings.live_trading = False
        proxy._order_check_override = None

        manage_result = gateway.manage(authorization=valid_auth)
        require(manage_result.get("managed") is False, "Management refusal failed.")
        require(
            manage_result.get("reason") == "MT5_MANAGEMENT_ENABLED_FALSE",
            f"Unexpected management refusal: {manage_result}",
        )
        require(proxy.order_send_attempts == 1, "Management reached order_send boundary.")
        emit("MANAGE_REFUSAL", "PASS")

        close_result = gateway.close(999999999, authorization=valid_auth)
        require(close_result.get("closed") is False, "Close refusal failed.")
        require(
            close_result.get("reason") == "MT5_LIVE_TRADING_FALSE",
            f"Unexpected close refusal: {close_result}",
        )
        require(proxy.order_send_attempts == 1, "Close reached order_send boundary.")
        emit("CLOSE_REFUSAL", "PASS")

        # Restore real positions_get before MT5 snapshot.
        proxy._positions_get_override = None

        # ------------------------------------------------------------------
        # Final live MT5 state: there must be no position/ticket change and no
        # new Abutron-magic deal since Step16 started.
        # ------------------------------------------------------------------
        after = snapshot_mt5(start_epoch)

        require(
            after["all_tickets"] == before["all_tickets"],
            "MT5 position ticket set changed during Step 16.",
        )
        require(
            after["magic_positions"] == before["magic_positions"],
            "Abutron-magic positions changed during Step 16.",
        )
        require(
            after["magic_deals"] == 0,
            f"Abutron-magic deals appeared during Step 16: {after['magic_deals']}",
        )

        emit("MT5_POSITIONS_UNCHANGED", "PASS")
        emit("ABUTRON_MAGIC_POSITIONS_UNCHANGED", "PASS")
        emit("NO_ABUTRON_MAGIC_DEALS", "PASS")

    finally:
        # Restore every process-local mutation even on failure.
        try:
            bridge_settings.live_trading = original_live
            gateway.settings.live_trading = original_live
            bridge_settings.management_enabled = original_management
            gateway.settings.management_enabled = original_management
        except Exception:
            pass

        try:
            gateway.mt5 = original_mt5
        except Exception:
            pass

        try:
            gateway.store = original_store
            bridge_settings.idempotency_db = original_db_path
            gateway.settings.idempotency_db = original_db_path
        except Exception:
            pass

        try:
            if native_initialized:
                native_mt5.shutdown()
        except Exception:
            pass

    # ----------------------------------------------------------------------
    # Production idempotency DB must contain none of the Step16 keys.
    # Run only after production setting/store are restored.
    # ----------------------------------------------------------------------
    require(
        str(bridge_settings.idempotency_db) == original_db_path,
        "Production idempotency DB path was not restored.",
    )
    require(gateway.store is original_store, "Production gateway store object was not restored.")
    require(bridge_settings.live_trading is original_live, "Local live_trading setting was not restored.")
    require(
        bridge_settings.management_enabled is original_management,
        "Local management setting was not restored.",
    )

    for key in tested_keys:
        require(
            original_store.get(key) is None,
            f"Step16 key leaked into production executions table: {key}",
        )
        require(
            not bool(original_store.claim_exists(key)),
            f"Step16 key leaked into production execution_claims table: {key}",
        )

    emit("PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED", "PASS")
    emit("PROCESS_LOCAL_SETTINGS_RESTORED", "PASS")

    shutil.rmtree(temp_dir, ignore_errors=True)
    emit("TEMP_CERTIFICATION_STORE_REMOVED", "PASS")

    emit("STEP_16_HELPER", "PASS")
    emit("REAL_GATEWAY_ORDER_FUNCTION_EXERCISED", "PASS")
    emit("HTTP_ORDER_ENDPOINT_CALLED", False)
    emit("HTTP_MANAGE_ENDPOINT_CALLED", False)
    emit("HTTP_CLOSE_ENDPOINT_CALLED", False)
    emit("BROKER_ORDER_SEND_CALLED", False)
    emit("NO_TRADES_SENT", True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
