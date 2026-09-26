from __future__ import annotations

import ast
import shutil
import sys
import textwrap
from pathlib import Path


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def fail(message: str) -> None:
    emit("STEP17_V3_PATCH", "FAILED")
    emit("FAILURE", message)
    raise SystemExit(2)


if len(sys.argv) != 2:
    fail("Usage: step17_v3_ast_repair.py <step17_controlled_demo_execution.py>")

target = Path(sys.argv[1])

if not target.exists():
    fail(f"Target helper not found: {target}")

source = target.read_text(encoding="utf-8-sig")

try:
    tree = ast.parse(source)
except SyntaxError as exc:
    fail(f"Existing Step 17 helper does not parse: {exc}")

if any(
    isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    and node.name == "wait_for_magic_deals"
    for node in tree.body
):
    emit("STEP17_V3_ALREADY_PATCHED", "PASS")
    emit("STEP17_V3_PATCH", "PASS")
    raise SystemExit(0)


def parse_function(src: str) -> ast.FunctionDef:
    node = ast.parse(textwrap.dedent(src)).body[0]
    if not isinstance(node, ast.FunctionDef):
        raise RuntimeError("Expected FunctionDef")
    return node


wait_fn = parse_function(
    '''
def wait_for_magic_deals(
    start_epoch: int,
    magic: int,
    symbol: str,
    minimum_count: int,
    seconds: int = 20,
):
    deadline = time.time() + seconds
    last = []

    while time.time() < deadline:
        try:
            last = magic_deals_since(
                start_epoch,
                magic,
                symbol,
            )
        except RuntimeError:
            last = []

        if len(last) >= minimum_count:
            return last

        time.sleep(0.5)

    return last
'''
)


emergency_fn = parse_function(
    '''
def emergency_close(ticket: int, magic: int) -> bool:
    candidates = [
        ("CONFIGURED", gateway._filling()),
        ("IOC", mt5.ORDER_FILLING_IOC),
        ("FOK", mt5.ORDER_FILLING_FOK),
        ("RETURN", mt5.ORDER_FILLING_RETURN),
    ]

    for cycle in range(1, 5):
        rows = mt5.positions_get(ticket=int(ticket))

        if rows is None:
            emit("EMERGENCY_POSITION_QUERY_ERROR", mt5.last_error())
            return False

        if len(rows) == 0:
            return True

        if len(rows) != 1:
            emit("EMERGENCY_POSITION_COUNT", len(rows))
            return False

        p = rows[0]

        owned = (
            int(getattr(p, "magic", 0) or 0) == int(magic)
            or str(getattr(p, "comment", "") or "")
            .upper()
            .startswith("ABUTRON")
        )

        if not owned:
            emit("EMERGENCY_OWNERSHIP_CHECK", "FAILED")
            return False

        tick = mt5.symbol_info_tick(p.symbol)

        if tick is None:
            emit("EMERGENCY_TICK", "UNAVAILABLE")
            time.sleep(1)
            continue

        is_buy = int(p.type) == int(mt5.POSITION_TYPE_BUY)
        selected = None
        seen = set()

        for fill_name, fill_value in candidates:
            fill_value = int(fill_value)

            if fill_value in seen:
                continue

            seen.add(fill_value)

            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "position": int(p.ticket),
                "symbol": p.symbol,
                "volume": float(p.volume),
                "type": (
                    mt5.ORDER_TYPE_SELL
                    if is_buy
                    else mt5.ORDER_TYPE_BUY
                ),
                "price": float(
                    tick.bid
                    if is_buy
                    else tick.ask
                ),
                "deviation": int(
                    max(
                        int(bridge_settings.deviation_points),
                        50,
                    )
                ),
                "magic": int(magic),
                "comment": "ABUTRON S17 EMERG",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": fill_value,
            }

            check = mt5.order_check(request)

            if check is None:
                emit(
                    f"EMERGENCY_CHECK_{fill_name}_RETCODE",
                    "NONE",
                )
                emit(
                    f"EMERGENCY_CHECK_{fill_name}_ERROR",
                    mt5.last_error(),
                )
                continue

            check_retcode = int(
                getattr(check, "retcode", -1)
            )

            emit(
                f"EMERGENCY_CHECK_{fill_name}_RETCODE",
                check_retcode,
            )
            emit(
                f"EMERGENCY_CHECK_{fill_name}_COMMENT",
                str(
                    getattr(check, "comment", "") or ""
                ).replace("\r", " ").replace("\n", " "),
            )

            if check_retcode == 0:
                selected = (
                    fill_name,
                    request,
                )
                break

        if selected is None:
            emit("EMERGENCY_SUPPORTED_FILLING", "NONE")
            return False

        fill_name, request = selected

        emit(
            "EMERGENCY_SELECTED_FILLING",
            fill_name,
        )
        emit(
            "EMERGENCY_SEND_CYCLE",
            cycle,
        )

        result = mt5.order_send(request)

        if result is None:
            emit(
                "EMERGENCY_SEND_NONE",
                mt5.last_error(),
            )
            time.sleep(1)
            continue

        retcode = int(
            getattr(result, "retcode", -1)
        )

        emit(
            "EMERGENCY_SEND_RETCODE",
            retcode,
        )
        emit(
            "EMERGENCY_SEND_COMMENT",
            str(
                getattr(result, "comment", "") or ""
            ).replace("\r", " ").replace("\n", " "),
        )

        if retcode in (
            int(mt5.TRADE_RETCODE_DONE),
            int(mt5.TRADE_RETCODE_DONE_PARTIAL),
        ):
            if wait_position_absent(
                ticket,
                seconds=15,
            ):
                return True

        time.sleep(1)

    return wait_position_absent(
        ticket,
        seconds=2,
    )
'''
)


class Step17Repair(ast.NodeTransformer):
    def __init__(self) -> None:
        self.magic_function_found = False
        self.emergency_replaced = False
        self.after_open_repaired = False
        self.final_repaired = False

    def visit_FunctionDef(self, node: ast.FunctionDef):
        if node.name == "magic_deals_since":
            self.magic_function_found = True
            return node

        if node.name == "emergency_close":
            self.emergency_replaced = True
            return ast.copy_location(emergency_fn, node)

        return self.generic_visit(node)

    def visit_Assign(self, node: ast.Assign):
        node = self.generic_visit(node)

        if len(node.targets) != 1:
            return node

        target_node = node.targets[0]

        if not isinstance(target_node, ast.Name):
            return node

        if not isinstance(node.value, ast.Call):
            return node

        call = node.value

        if not isinstance(call.func, ast.Name):
            return node

        if call.func.id != "magic_deals_since":
            return node

        if target_node.id == "after_open_deals":
            call.func = ast.Name(
                id="wait_for_magic_deals",
                ctx=ast.Load(),
            )
            call.args.append(
                ast.BinOp(
                    left=ast.Name(
                        id="baseline_magic_deals",
                        ctx=ast.Load(),
                    ),
                    op=ast.Add(),
                    right=ast.Constant(value=1),
                )
            )
            self.after_open_repaired = True
            return node

        if target_node.id == "final_deals":
            call.func = ast.Name(
                id="wait_for_magic_deals",
                ctx=ast.Load(),
            )
            call.args.append(
                ast.BinOp(
                    left=ast.Name(
                        id="baseline_magic_deals",
                        ctx=ast.Load(),
                    ),
                    op=ast.Add(),
                    right=ast.Constant(value=2),
                )
            )
            self.final_repaired = True
            return node

        return node


repair = Step17Repair()
tree = repair.visit(tree)
ast.fix_missing_locations(tree)

if not repair.magic_function_found:
    fail("magic_deals_since() was not found.")

if not repair.emergency_replaced:
    fail("emergency_close() was not found.")

if not repair.after_open_repaired:
    fail("after_open_deals reconciliation assignment was not found.")

if not repair.final_repaired:
    fail("final_deals reconciliation assignment was not found.")

insert_at = None

for index, node in enumerate(tree.body):
    if (
        isinstance(node, ast.FunctionDef)
        and node.name == "magic_deals_since"
    ):
        insert_at = index + 1
        break

if insert_at is None:
    fail("Could not locate insertion point after magic_deals_since().")

tree.body.insert(insert_at, wait_fn)
ast.fix_missing_locations(tree)

try:
    repaired_source = ast.unparse(tree) + "\n"
    ast.parse(repaired_source)
except Exception as exc:
    fail(f"Repaired source failed AST validation: {exc}")

backup = target.with_suffix(
    target.suffix + ".before-step17-v3.bak"
)

if not backup.exists():
    shutil.copy2(target, backup)

target.write_text(
    repaired_source,
    encoding="utf-8",
)

emit("STEP17_V3_BACKUP", str(backup))
emit("STEP17_V3_HISTORY_POLLING", "PASS")
emit("STEP17_V3_EMERGENCY_CLOSE_REPAIR", "PASS")
emit("STEP17_V3_AST_VALIDATION", "PASS")
emit("STEP17_V3_PATCH", "PASS")
