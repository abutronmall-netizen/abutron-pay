from __future__ import annotations

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as mt5
from mt5_bridge.settings import settings


def emit(k, v):
    print(f"{k}={v}", flush=True)


def require(ok, msg):
    if not ok:
        raise RuntimeError(msg)


terminal_path = sys.argv[1]

emit("STEP17_HISTORY_DIAGNOSTIC", "START")
emit("MODE", "READ_ONLY")
emit("ORDER_SEND_CALLED", False)
emit("ORDER_CLOSE_CALLED", False)

require(settings.demo_only is True, "MT5_DEMO_ONLY must be true.")
require(settings.live_trading is False, "Production live trading must remain false.")
require(settings.management_enabled is False, "Management must remain false.")

if not mt5.initialize(path=terminal_path):
    raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

try:
    terminal = mt5.terminal_info()
    account = mt5.account_info()

    require(terminal is not None, "terminal_info unavailable")
    require(account is not None, "account_info unavailable")
    require(bool(terminal.connected), "MT5 not connected")

    emit("MT5_CONNECTED", True)
    emit("DEMO_SERVER", "DEMO" in str(account.server).upper())
    emit("ACCOUNT_LOGIN_PRINTED", False)

    now = datetime.now(timezone.utc)
    start = now - timedelta(hours=2)

    deals = mt5.history_deals_get(start, now)

    require(
        deals is not None,
        f"history_deals_get failed: {mt5.last_error()}"
    )

    deals = list(deals)

    emit("TOTAL_DEALS_LAST_2H", len(deals))

    candidates = []

    for d in deals:
        symbol = str(getattr(d, "symbol", "") or "")
        comment = str(getattr(d, "comment", "") or "")
        magic = int(getattr(d, "magic", 0) or 0)

        if (
            magic == int(settings.magic)
            or symbol.upper().startswith("XAUUSD")
            or comment.upper().startswith("ABUTRON")
        ):
            candidates.append(d)

    emit("STEP17_CANDIDATE_DEALS", len(candidates))

    for i, d in enumerate(candidates, 1):

        emit(f"DEAL_{i}_TICKET", int(getattr(d, "ticket", 0) or 0))
        emit(f"DEAL_{i}_ORDER", int(getattr(d, "order", 0) or 0))
        emit(
            f"DEAL_{i}_POSITION_ID",
            int(getattr(d, "position_id", 0) or 0)
        )
        emit(f"DEAL_{i}_MAGIC", int(getattr(d, "magic", 0) or 0))
        emit(
            f"DEAL_{i}_SYMBOL",
            str(getattr(d, "symbol", "") or "")
        )
        emit(
            f"DEAL_{i}_ENTRY",
            int(getattr(d, "entry", -1))
        )
        emit(
            f"DEAL_{i}_TYPE",
            int(getattr(d, "type", -1))
        )
        emit(
            f"DEAL_{i}_VOLUME",
            float(getattr(d, "volume", 0.0) or 0.0)
        )
        emit(
            f"DEAL_{i}_COMMENT",
            str(getattr(d, "comment", "") or "")
            .replace("\r", " ")
            .replace("\n", " ")
        )
        emit(
            f"DEAL_{i}_TIME",
            int(getattr(d, "time", 0) or 0)
        )

    magic_matches = [
        d for d in candidates
        if int(getattr(d, "magic", 0) or 0)
        == int(settings.magic)
    ]

    symbol_matches = [
        d for d in candidates
        if str(getattr(d, "symbol", "") or "")
        .upper()
        .startswith("XAUUSD")
    ]

    comment_matches = [
        d for d in candidates
        if str(getattr(d, "comment", "") or "")
        .upper()
        .startswith("ABUTRON")
    ]

    emit("MAGIC_MATCH_COUNT", len(magic_matches))
    emit("XAUUSD_FAMILY_COUNT", len(symbol_matches))
    emit("ABUTRON_COMMENT_COUNT", len(comment_matches))

    positions = mt5.positions_get()

    require(
        positions is not None,
        f"positions_get failed: {mt5.last_error()}"
    )

    abutron_positions = [
        p for p in positions
        if int(getattr(p, "magic", 0) or 0) == int(settings.magic)
        or str(getattr(p, "comment", "") or "")
           .upper()
           .startswith("ABUTRON")
    ]

    emit("CURRENT_ABUTRON_POSITION_COUNT", len(abutron_positions))
    emit(
        "ZERO_CURRENT_ABUTRON_EXPOSURE",
        len(abutron_positions) == 0
    )

    emit("STEP17_HISTORY_DIAGNOSTIC", "PASS")

finally:
    mt5.shutdown()
