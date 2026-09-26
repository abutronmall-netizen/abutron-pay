from __future__ import annotations

import ast
import sys
from pathlib import Path


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")


# ----------------------------------------------------------
# IDEMPOTENT CHECK
# ----------------------------------------------------------

if "STEP17_V4_HISTORY_BASELINE_DELTA" in source:
    ast.parse(source)

    print("STEP17_V4_ALREADY_PATCHED=True")
    print("STEP17_V4_HISTORY_PATCH=PASS")
    raise SystemExit(0)


# ----------------------------------------------------------
# IMPORT timedelta
# ----------------------------------------------------------

old_import = "from datetime import datetime, timezone"
new_import = "from datetime import datetime, timedelta, timezone"

if old_import in source:
    source = source.replace(
        old_import,
        new_import,
        1,
    )
elif new_import not in source:
    raise RuntimeError(
        "Step 17 datetime import shape was not recognized."
    )


# ----------------------------------------------------------
# LOCATE history_since()
# ----------------------------------------------------------

tree = ast.parse(source)

functions = {
    node.name: node
    for node in tree.body
    if isinstance(node, ast.FunctionDef)
}

history_node = functions.get("history_since")

if history_node is None:
    raise RuntimeError(
        "history_since function was not found."
    )


replacement = '''def history_since(start_epoch: int):
    # STEP17_V4_HISTORY_BASELINE_DELTA
    #
    # The production MT5 terminal has demonstrated that short history
    # windows can miss fresh broker records while broader windows expose
    # them correctly. Step 17 therefore uses a broad read-only broker
    # history window and proves a new execution by comparing against the
    # baseline count captured BEFORE the certification order.
    #
    # start_epoch remains in the function signature to preserve the
    # existing Step 17 interface.
    _ = start_epoch

    now = datetime.now(timezone.utc)

    rows = mt5.history_deals_get(
        now - timedelta(days=7),
        now + timedelta(days=1),
    )

    if rows is None:
        raise RuntimeError(
            f"MT5 history_deals_get failed: {mt5.last_error()}"
        )

    return list(rows)
'''


# ----------------------------------------------------------
# REPLACE FUNCTION
# ----------------------------------------------------------

lines = source.splitlines(keepends=True)

lines[
    history_node.lineno - 1 :
    history_node.end_lineno
] = [
    replacement + "\n"
]

repaired = "".join(lines)


# ----------------------------------------------------------
# VALIDATE COMPLETE HELPER
# ----------------------------------------------------------

tree = ast.parse(repaired)

function_names = {
    node.name
    for node in ast.walk(tree)
    if isinstance(node, ast.FunctionDef)
}

required_functions = {
    "history_since",
    "magic_deals_since",
    "wait_for_magic_deals",
    "emergency_close",
}

missing = required_functions - function_names

if missing:
    raise RuntimeError(
        "Required Step 17 V3/V4 functions missing: "
        + ",".join(sorted(missing))
    )


required_markers = (
    "STEP17_V4_HISTORY_BASELINE_DELTA",
    "timedelta(days=7)",
    "timedelta(days=1)",
    "wait_for_magic_deals",
    "EMERGENCY_SELECTED_FILLING",
)

for marker in required_markers:
    if marker not in repaired:
        raise RuntimeError(
            f"Required Step 17 marker missing: {marker}"
        )


path.write_text(
    repaired,
    encoding="utf-8",
)

print("STEP17_V4_HISTORY_BASELINE_DELTA=PASS")
print("STEP17_V3_HISTORY_POLLING_PRESERVED=PASS")
print("STEP17_V3_EMERGENCY_CLOSE_PRESERVED=PASS")
print("STEP17_V4_HISTORY_PATCH=PASS")
