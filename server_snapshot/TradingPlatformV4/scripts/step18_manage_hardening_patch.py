from __future__ import annotations

import ast
import shutil
import sys
from pathlib import Path


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def fail(message: str) -> None:
    emit("STEP18_MANAGEMENT_HARDENING_PATCH", "FAILED")
    emit("FAILURE", message)
    raise SystemExit(2)


if len(sys.argv) != 2:
    fail("Usage: step18_manage_hardening_patch.py <mt5_bridge/app.py>")

path = Path(sys.argv[1])

if not path.exists():
    fail(f"Target not found: {path}")

source = path.read_text(encoding="utf-8-sig")

try:
    tree = ast.parse(source)
except SyntaxError as exc:
    fail(f"Existing gateway source does not parse: {exc}")

if "STEP18_MANAGEMENT_HARDENING_V1" in source:
    required = (
        "trade_stops_level",
        "trade_freeze_level",
        "order_check",
        "MANAGE_BROKER_CONSTRAINT",
    )
    for marker in required:
        if marker not in source:
            fail(f"Partial Step18 hardening detected; missing {marker}")
    emit("STEP18_MANAGEMENT_HARDENING_ALREADY_PRESENT", "PASS")
    emit("STEP18_MANAGEMENT_HARDENING_PATCH", "PASS")
    raise SystemExit(0)

manage_node = None

for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name == "manage":
        manage_node = node
        break

if manage_node is None:
    fail("manage() function not found in mt5_bridge/app.py")

replacement = '''def manage(authorization:str|None=Header(default=None)):
    # STEP18_MANAGEMENT_HARDENING_V1
    auth(authorization)
    ready()

    if not settings.management_enabled:
        return {
            "managed": False,
            "reason": "MT5_MANAGEMENT_ENABLED_FALSE",
            "actions": [],
        }

    _require_demo_if_configured()

    import math

    actions = []

    for p in (mt5.positions_get() or []):
        if not _is_abutron_position(p):
            continue

        if not p.sl:
            continue

        meta = store.get_position(int(p.ticket))

        initial_r = (
            float(meta["initial_r"])
            if meta
            else abs(float(p.price_open) - float(p.sl))
        )

        if initial_r <= 0:
            continue

        current = float(p.price_current)
        entry = float(p.price_open)
        old_sl = float(p.sl)
        tp = float(p.tp)
        is_buy = p.type == mt5.POSITION_TYPE_BUY

        favorable = (
            current - entry
            if is_buy
            else entry - current
        )

        requested_sl = old_sl

        if (
            settings.break_even_enabled
            and favorable >= settings.break_even_r * initial_r
        ):
            requested_sl = (
                max(requested_sl, entry)
                if is_buy
                else min(requested_sl, entry)
            )

        if (
            settings.trailing_enabled
            and favorable >= settings.trail_start_r * initial_r
        ):
            candidate = (
                current - settings.trail_distance_r * initial_r
                if is_buy
                else current + settings.trail_distance_r * initial_r
            )

            requested_sl = (
                max(requested_sl, candidate)
                if is_buy
                else min(requested_sl, candidate)
            )

        improves_requested = (
            requested_sl > old_sl + 1e-12
            if is_buy
            else requested_sl < old_sl - 1e-12
        )

        if not improves_requested:
            continue

        info = mt5.symbol_info(p.symbol)
        tick = mt5.symbol_info_tick(p.symbol)

        if info is None or tick is None:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": old_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_MARKET_INFO_UNAVAILABLE",
            })
            continue

        point = float(getattr(info, "point", 0.0) or 0.0)
        tick_size = float(
            getattr(info, "trade_tick_size", 0.0)
            or point
            or 0.0
        )

        if tick_size <= 0:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": old_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_INVALID_TICK_SIZE",
            })
            continue

        stops_level = int(
            getattr(info, "trade_stops_level", 0)
            or 0
        )
        freeze_level = int(
            getattr(info, "trade_freeze_level", 0)
            or 0
        )

        broker_points = max(
            stops_level,
            freeze_level,
            0,
        )

        broker_distance = (
            float(broker_points) * point
            + tick_size
        )

        market_reference = float(
            tick.bid
            if is_buy
            else tick.ask
        )

        if is_buy:
            broker_limit = market_reference - broker_distance
            broker_limit = (
                math.floor(broker_limit / tick_size)
                * tick_size
            )
            safe_sl = min(requested_sl, broker_limit)
            safe_sl = (
                math.floor(safe_sl / tick_size)
                * tick_size
            )
        else:
            broker_limit = market_reference + broker_distance
            broker_limit = (
                math.ceil(broker_limit / tick_size)
                * tick_size
            )
            safe_sl = max(requested_sl, broker_limit)
            safe_sl = (
                math.ceil(safe_sl / tick_size)
                * tick_size
            )

        safe_sl = round(
            safe_sl,
            int(getattr(info, "digits", 10) or 10),
        )

        improves_safe = (
            safe_sl > old_sl + 1e-12
            if is_buy
            else safe_sl < old_sl - 1e-12
        )

        if not improves_safe:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": old_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_BROKER_CONSTRAINT_NO_SAFE_IMPROVEMENT",
            })
            continue

        req = {
            "action": mt5.TRADE_ACTION_SLTP,
            "position": int(p.ticket),
            "symbol": p.symbol,
            "sl": float(safe_sl),
            "tp": tp,
            "magic": settings.magic,
        }

        check = mt5.order_check(req)

        if check is None:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": safe_sl,
                "ok": False,
                "retcode": None,
                "reason": "MANAGE_ORDER_CHECK_NONE",
            })
            continue

        check_retcode = int(
            getattr(check, "retcode", -1)
        )

        if check_retcode != 0:
            actions.append({
                "ticket": int(p.ticket),
                "old_sl": old_sl,
                "new_sl": safe_sl,
                "ok": False,
                "retcode": check_retcode,
                "reason": "MANAGE_ORDER_CHECK_REJECTED",
            })
            continue

        res = mt5.order_send(req)

        actions.append({
            "ticket": int(p.ticket),
            "old_sl": old_sl,
            "new_sl": safe_sl,
            "requested_sl": float(requested_sl),
            "broker_limit": float(broker_limit),
            "broker_stops_level": stops_level,
            "broker_freeze_level": freeze_level,
            "ok": bool(
                res
                and res.retcode == mt5.TRADE_RETCODE_DONE
            ),
            "retcode": int(res.retcode) if res else None,
            "reason": (
                "MANAGE_SLTP_DONE"
                if (
                    res
                    and res.retcode == mt5.TRADE_RETCODE_DONE
                )
                else "MANAGE_SLTP_FAILED"
            ),
        })

    return {
        "managed": True,
        "actions": actions,
    }
'''

lines = source.splitlines(keepends=True)
lines[manage_node.lineno - 1 : manage_node.end_lineno] = [replacement + "\n\n"]
patched = "".join(lines)

try:
    ast.parse(patched)
except SyntaxError as exc:
    fail(f"Patched source failed AST validation: {exc}")

for marker in (
    "STEP18_MANAGEMENT_HARDENING_V1",
    "trade_stops_level",
    "trade_freeze_level",
    "MANAGE_BROKER_CONSTRAINT_NO_SAFE_IMPROVEMENT",
    "MANAGE_ORDER_CHECK_REJECTED",
    "order_check",
):
    if marker not in patched:
        fail(f"Patched source missing marker: {marker}")

backup = path.with_suffix(
    path.suffix + ".before-step18-management-hardening.bak"
)

if not backup.exists():
    shutil.copy2(path, backup)

path.write_text(
    patched,
    encoding="utf-8",
)

emit("STEP18_GATEWAY_BACKUP", str(backup))
emit("STEP18_STOP_LEVEL_GUARD", "PASS")
emit("STEP18_FREEZE_LEVEL_GUARD", "PASS")
emit("STEP18_TICK_SIZE_NORMALIZATION", "PASS")
emit("STEP18_ORDER_CHECK_BEFORE_SLTP", "PASS")
emit("STEP18_NO_WORSENING_GUARD_PRESERVED", "PASS")
emit("STEP18_MANAGEMENT_HARDENING_PATCH", "PASS")
