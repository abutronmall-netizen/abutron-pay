from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse, unquote

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
ENV_FILE = ROOT / ".env"
LEDGER = ROOT / "logs" / "step19_tier_evidence.json"
MAGIC = 400040
EXPECTED_PROFILES = {
    "FLIPPER": "flipper-v4-adaptive-directional",
    "SCALPER": "scalper-v4-precision-sniper",
    "MASTER": "master-v4-mtf-capital",
}
ACCEPTED_STEP19_MARKERS = {
    "STEP19_EQUITY_ROUTER_BOT_LIFECYCLE_V1",
    "STEP19_MULTI_DEMO_CERT_V1_3",
    "STEP19_MULTI_DEMO_CERT_V1_4",
}
BUILD_MARKER = "STEP20_SOAK_ENDURANCE_CERT_V1"


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        values[key] = value
    return values


def bool_env(values: dict[str, str], name: str) -> bool:
    raw = str(values.get(name, "")).strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    raise RuntimeError(f"{name}_INVALID_OR_MISSING")


def validate_safety(env: dict[str, str]) -> None:
    require(bool_env(env, "ABUTRON_EXECUTION_ENABLED") is False, "ABUTRON_EXECUTION_ENABLED_MUST_BE_FALSE")
    require(bool_env(env, "MT5_LIVE_TRADING") is False, "MT5_LIVE_TRADING_MUST_BE_FALSE")
    require(bool_env(env, "MT5_MANAGEMENT_ENABLED") is False, "MT5_MANAGEMENT_ENABLED_MUST_BE_FALSE")
    require(bool_env(env, "MT5_DEMO_ONLY") is True, "MT5_DEMO_ONLY_MUST_BE_TRUE")
    emit("STEP20_PRODUCTION_SAFETY", "PASS")


def validate_step19_ledger(env: dict[str, str]) -> None:
    require(LEDGER.exists(), "STEP19_LEDGER_MISSING")
    try:
        value = json.loads(LEDGER.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"STEP19_LEDGER_JSON_INVALID:{type(exc).__name__}") from exc
    require(isinstance(value, dict), "STEP19_LEDGER_NOT_OBJECT")
    expected_server = str(env.get("MT5_EXPECTED_SERVER", "")).strip()
    require(bool(expected_server), "MT5_EXPECTED_SERVER_REQUIRED")
    for tier, profile in EXPECTED_PROFILES.items():
        entry = value.get(tier)
        require(isinstance(entry, dict), f"STEP19_{tier}_EVIDENCE_MISSING")
        require(entry.get("status") == "PASS", f"STEP19_{tier}_STATUS_NOT_PASS")
        require(str(entry.get("build_marker", "")) in ACCEPTED_STEP19_MARKERS, f"STEP19_{tier}_BUILD_MARKER_INVALID")
        require(str(entry.get("symbol", "")).upper() == "XAUUSD", f"STEP19_{tier}_SYMBOL_INVALID")
        require(str(entry.get("strategy_profile", "")) == profile, f"STEP19_{tier}_PROFILE_INVALID")
        require(str(entry.get("server", "")).casefold() == expected_server.casefold(), f"STEP19_{tier}_SERVER_INVALID")
        require(int(entry.get("position_ticket", 0) or 0) > 0, f"STEP19_{tier}_TICKET_INVALID")
        require(int(entry.get("certified_ts", 0) or 0) > 0, f"STEP19_{tier}_TIMESTAMP_INVALID")
        require(str(entry.get("signal_id", "")).startswith("STEP19-"), f"STEP19_{tier}_SIGNAL_INVALID")
        emit(f"STEP20_STEP19_{tier}", "PASS")
    emit("STEP20_STEP19_PREREQUISITE", "PASS")


def database_probe(env: dict[str, str]) -> None:
    try:
        from sqlalchemy import text
        from abutron.platform_db import session_scope
        with session_scope() as session:
            value = session.execute(text("SELECT 1")).scalar_one()
        require(int(value) == 1, "DATABASE_SELECT_ONE_FAILED")
    except Exception as exc:
        raise RuntimeError(f"DATABASE_PROBE_FAILED:{type(exc).__name__}:{exc}") from exc
    emit("STEP20_DATABASE_CONNECTIVITY", "PASS")


def _recv_line(sock: socket.socket) -> bytes:
    data = bytearray()
    while True:
        ch = sock.recv(1)
        if not ch:
            break
        data += ch
        if data.endswith(b"\r\n"):
            break
    return bytes(data)


def redis_probe(env: dict[str, str]) -> None:
    raw = str(env.get("REDIS_URL", "redis://127.0.0.1:6379/0")).strip()
    parsed = urlparse(raw)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 6379
    password = unquote(parsed.password) if parsed.password else None
    try:
        with socket.create_connection((host, port), timeout=5) as sock:
            sock.settimeout(5)
            if password:
                payload = password.encode("utf-8")
                cmd = b"*2\r\n$4\r\nAUTH\r\n$" + str(len(payload)).encode() + b"\r\n" + payload + b"\r\n"
                sock.sendall(cmd)
                auth = _recv_line(sock)
                require(auth.startswith(b"+OK"), "REDIS_AUTH_FAILED")
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            reply = _recv_line(sock)
            require(reply.startswith(b"+PONG"), "REDIS_PING_FAILED")
    except Exception as exc:
        raise RuntimeError(f"REDIS_PROBE_FAILED:{type(exc).__name__}:{exc}") from exc
    emit("STEP20_REDIS_CONNECTIVITY", "PASS")


def _abutron_owned(item) -> bool:
    magic = int(getattr(item, "magic", 0) or 0)
    comment = str(getattr(item, "comment", "") or "").upper()
    return magic == MAGIC or comment.startswith("ABUTRON")


def mt5_probe(env: dict[str, str], mt5_path: str, start_epoch: int) -> None:
    import MetaTrader5 as mt5
    expected_server = str(env.get("MT5_EXPECTED_SERVER", "")).strip()
    expected_login = str(env.get("MT5_EXPECTED_LOGIN", "")).strip()
    require(bool(expected_server), "MT5_EXPECTED_SERVER_REQUIRED")
    require(bool(expected_login) and expected_login.isdigit(), "MT5_EXPECTED_LOGIN_REQUIRED")
    ok = mt5.initialize(path=mt5_path)
    require(bool(ok), f"MT5_INIT_FAILED:{mt5.last_error()}")
    try:
        terminal = mt5.terminal_info()
        account = mt5.account_info()
        require(terminal is not None and bool(terminal.connected), "MT5_TERMINAL_NOT_CONNECTED")
        require(account is not None, "MT5_ACCOUNT_INFO_MISSING")
        require(str(account.server).casefold() == expected_server.casefold(), "MT5_EXPECTED_SERVER_MISMATCH")
        require(str(account.login) == expected_login, "MT5_EXPECTED_LOGIN_MISMATCH")
        require(int(account.trade_mode) == int(mt5.ACCOUNT_TRADE_MODE_DEMO), "MT5_ACCOUNT_NOT_DEMO")

        positions = mt5.positions_get()
        orders = mt5.orders_get()
        require(positions is not None, f"MT5_POSITIONS_FAILED:{mt5.last_error()}")
        require(orders is not None, f"MT5_ORDERS_FAILED:{mt5.last_error()}")
        owned_positions = [p for p in positions if _abutron_owned(p)]
        owned_orders = [o for o in orders if _abutron_owned(o)]
        emit("STEP20_MT5_CONNECTED", "PASS")
        emit("STEP20_MT5_EXPECTED_LOGIN", "PASS")
        emit("STEP20_MT5_EXPECTED_SERVER", "PASS")
        emit("STEP20_MT5_DEMO_MODE", "PASS")
        emit("STEP20_ABUTRON_OPEN_POSITIONS", len(owned_positions))
        emit("STEP20_ABUTRON_PENDING_ORDERS", len(owned_orders))
        require(len(owned_positions) == 0, "ABUTRON_POSITION_BASELINE_NOT_ZERO")
        require(len(owned_orders) == 0, "ABUTRON_PENDING_ORDER_BASELINE_NOT_ZERO")

        if start_epoch > 0:
            start = datetime.fromtimestamp(start_epoch, tz=timezone.utc)
            now = datetime.now(timezone.utc)
            deals = mt5.history_deals_get(start, now)
            require(deals is not None, f"MT5_HISTORY_DEALS_FAILED:{mt5.last_error()}")
            owned_deals = [d for d in deals if _abutron_owned(d)]
            emit("STEP20_ABUTRON_DEALS_SINCE_START", len(owned_deals))
            require(len(owned_deals) == 0, "UNINTENDED_ABUTRON_DEAL_DETECTED")
    finally:
        mt5.shutdown()
    emit("STEP20_MT5_READ_ONLY_PROBE", "PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["preflight", "infra", "mt5"], required=True)
    parser.add_argument("--mt5-path", default="")
    parser.add_argument("--start-epoch", type=int, default=0)
    args = parser.parse_args()

    emit("STEP20_BUILD_MARKER", BUILD_MARKER)
    require(ENV_FILE.exists(), "PRODUCTION_ENV_MISSING")
    env = parse_env(ENV_FILE)
    validate_safety(env)

    if args.mode == "preflight":
        validate_step19_ledger(env)
        database_probe(env)
        redis_probe(env)
        require(bool(args.mt5_path), "MT5_PATH_REQUIRED")
        mt5_probe(env, args.mt5_path, 0)
        emit("STEP20_HELPER_PREFLIGHT", "PASS")
    elif args.mode == "infra":
        database_probe(env)
        redis_probe(env)
        emit("STEP20_HELPER_INFRA", "PASS")
    else:
        require(bool(args.mt5_path), "MT5_PATH_REQUIRED")
        mt5_probe(env, args.mt5_path, args.start_epoch)
        emit("STEP20_HELPER_MT5", "PASS")

    emit("LIVE_MONEY_AUTHORIZED", "False")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        emit("STEP20_HELPER_ERROR", str(exc))
        emit("LIVE_MONEY_AUTHORIZED", "False")
        raise
