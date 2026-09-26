from __future__ import annotations

import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as mt5
from mt5_bridge.settings import settings


def emit(key, value):
    print(f"{key}={value}", flush=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def safe_len(value):
    if value is None:
        return -1
    return len(value)


def query_window(label, start, end):
    deals = mt5.history_deals_get(start, end)
    deals_err = mt5.last_error()

    orders = mt5.history_orders_get(start, end)
    orders_err = mt5.last_error()

    emit(label + "_DEALS", safe_len(deals))
    emit(label + "_DEALS_LAST_ERROR", str(deals_err))

    emit(label + "_ORDERS", safe_len(orders))
    emit(label + "_ORDERS_LAST_ERROR", str(orders_err))

    try:
        total = mt5.history_deals_total(start, end)
    except Exception as exc:
        total = "EXCEPTION:" + str(exc)

    emit(label + "_DEALS_TOTAL", total)

    return deals, orders


emit("STEP17_HISTORY_MATRIX", "START")
emit("MODE", "READ_ONLY")
emit("ORDER_SEND_CALLED", False)
emit("ORDER_CLOSE_CALLED", False)

require(
    settings.live_trading is False,
    "MT5_LIVE_TRADING must remain false."
)

require(
    settings.management_enabled is False,
    "MT5_MANAGEMENT_ENABLED must remain false."
)

require(
    settings.demo_only is True,
    "MT5_DEMO_ONLY must remain true."
)

if not mt5.initialize(path=sys.argv[1]):
    raise RuntimeError(
        f"MT5 initialize failed: {mt5.last_error()}"
    )

try:
    terminal = mt5.terminal_info()
    account = mt5.account_info()

    require(terminal is not None, "terminal_info unavailable.")
    require(account is not None, "account_info unavailable.")
    require(bool(terminal.connected), "MT5 is not connected.")

    emit("MT5_CONNECTED", True)
    emit(
        "DEMO_SERVER",
        "DEMO" in str(getattr(account, "server", "")).upper()
    )
    emit("ACCOUNT_LOGIN_PRINTED", False)

    now_epoch = int(time.time())

    now_utc = datetime.now(timezone.utc)
    now_local = datetime.now()

    emit("SYSTEM_EPOCH_NOW", now_epoch)
    emit("UTC_NOW_ISO", now_utc.isoformat())
    emit("LOCAL_NOW_ISO", now_local.isoformat())

    tick = mt5.symbol_info_tick("XAUUSD")

    if tick is not None:
        tick_epoch = int(getattr(tick, "time", 0) or 0)

        emit("XAUUSD_TICK_AVAILABLE", True)
        emit("XAUUSD_TICK_EPOCH", tick_epoch)
        emit(
            "SYSTEM_MINUS_TICK_SECONDS",
            now_epoch - tick_epoch
        )
    else:
        emit("XAUUSD_TICK_AVAILABLE", False)

    emit("", "")

    # --------------------------------------------------
    # TEST 1
    # timezone-aware UTC datetime
    # --------------------------------------------------

    query_window(
        "AWARE_UTC_4H",
        now_utc - timedelta(hours=4),
        now_utc + timedelta(minutes=10),
    )

    # --------------------------------------------------
    # TEST 2
    # naive local datetime, matching MetaQuotes examples
    # --------------------------------------------------

    query_window(
        "NAIVE_LOCAL_4H",
        now_local - timedelta(hours=4),
        now_local + timedelta(minutes=10),
    )

    # --------------------------------------------------
    # TEST 3
    # raw epoch seconds
    # --------------------------------------------------

    query_window(
        "EPOCH_4H",
        now_epoch - (4 * 60 * 60),
        now_epoch + (10 * 60),
    )

    # --------------------------------------------------
    # TEST 4-6
    # wider seven-day versions
    # --------------------------------------------------

    query_window(
        "AWARE_UTC_7D",
        now_utc - timedelta(days=7),
        now_utc + timedelta(hours=1),
    )

    query_window(
        "NAIVE_LOCAL_7D",
        now_local - timedelta(days=7),
        now_local + timedelta(hours=1),
    )

    query_window(
        "EPOCH_7D",
        now_epoch - (7 * 24 * 60 * 60),
        now_epoch + (60 * 60),
    )

    # --------------------------------------------------
    # TEST 7
    # Wide window to determine whether this terminal
    # exposes any account history at all.
    # --------------------------------------------------

    wide_start = datetime(2020, 1, 1)
    wide_end = datetime.now() + timedelta(days=1)

    wide_deals, wide_orders = query_window(
        "WIDE_HISTORY",
        wide_start,
        wide_end,
    )

    # --------------------------------------------------
    # Print only non-sensitive structural details
    # from newest visible history entries.
    # --------------------------------------------------

    if wide_deals:
        newest_deal = max(
            wide_deals,
            key=lambda d: int(
                getattr(d, "time_msc", 0)
                or getattr(d, "time", 0)
                or 0
            ),
        )

        emit("NEWEST_DEAL_PRESENT", True)
        emit(
            "NEWEST_DEAL_TIME",
            int(getattr(newest_deal, "time", 0) or 0)
        )
        emit(
            "NEWEST_DEAL_MAGIC",
            int(getattr(newest_deal, "magic", 0) or 0)
        )
        emit(
            "NEWEST_DEAL_SYMBOL",
            str(getattr(newest_deal, "symbol", "") or "")
        )
        emit(
            "NEWEST_DEAL_COMMENT",
            str(getattr(newest_deal, "comment", "") or "")
            .replace("\r", " ")
            .replace("\n", " ")
        )
    else:
        emit("NEWEST_DEAL_PRESENT", False)

    if wide_orders:
        newest_order = max(
            wide_orders,
            key=lambda o: int(
                getattr(o, "time_done_msc", 0)
                or getattr(o, "time_setup_msc", 0)
                or getattr(o, "time_done", 0)
                or getattr(o, "time_setup", 0)
                or 0
            ),
        )

        emit("NEWEST_ORDER_PRESENT", True)
        emit(
            "NEWEST_ORDER_MAGIC",
            int(getattr(newest_order, "magic", 0) or 0)
        )
        emit(
            "NEWEST_ORDER_SYMBOL",
            str(getattr(newest_order, "symbol", "") or "")
        )
        emit(
            "NEWEST_ORDER_COMMENT",
            str(getattr(newest_order, "comment", "") or "")
            .replace("\r", " ")
            .replace("\n", " ")
        )
    else:
        emit("NEWEST_ORDER_PRESENT", False)

    positions = mt5.positions_get()

    require(
        positions is not None,
        f"positions_get failed: {mt5.last_error()}"
    )

    abutron_positions = [
        p
        for p in positions
        if int(getattr(p, "magic", 0) or 0)
           == int(settings.magic)
        or str(getattr(p, "comment", "") or "")
           .upper()
           .startswith("ABUTRON")
    ]

    emit(
        "CURRENT_ABUTRON_POSITION_COUNT",
        len(abutron_positions)
    )

    emit(
        "ZERO_CURRENT_ABUTRON_EXPOSURE",
        len(abutron_positions) == 0
    )

    emit("STEP17_HISTORY_MATRIX", "PASS")

finally:
    mt5.shutdown()
