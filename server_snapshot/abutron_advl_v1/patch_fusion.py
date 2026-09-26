from __future__ import annotations

import ast
import shutil
import sys
import time
from pathlib import Path


MARKER = "# ABUTRON_ADVL_V1"
IMPORT_LINE = "from abutron.advl import blend_advl_confirmation, get_advl_feature  # ABUTRON_ADVL_V1"


def fail(message: str) -> None:
    raise RuntimeError(message)


def _import_insert_index(tree: ast.Module, lines: list[str]) -> int:
    """Return a safe line index after module docstring and __future__ imports."""
    index = 0
    body = tree.body
    pos = 0

    if body and isinstance(body[0], ast.Expr):
        value = body[0].value
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            index = int(getattr(body[0], "end_lineno", body[0].lineno))
            pos = 1

    while pos < len(body):
        node = body[pos]
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            index = int(getattr(node, "end_lineno", node.lineno))
            pos += 1
            continue
        break

    # Preserve any immediately following blank line by inserting before it only
    # when index is zero; otherwise insert exactly after the protected statements.
    return max(0, min(index, len(lines)))


def patch(root: Path) -> Path:
    pkg = root / "abutron"
    fusion = pkg / "fusion.py"
    advl_src = Path(__file__).resolve().parent / "advl.py"
    advl_dst = pkg / "advl.py"

    if not fusion.exists():
        fail(f"Missing production file: {fusion}")
    if not advl_src.exists():
        fail(f"Missing package file: {advl_src}")

    source = fusion.read_text(encoding="utf-8")
    try:
        tree = ast.parse(source)
    except SyntaxError as exc:
        fail(f"fusion.py does not parse before patch: {exc}")

    stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns() % 1_000_000_000:09d}"
    backup_dir = root / "backups" / f"advl-v1-{stamp}"
    backup_dir.mkdir(parents=True, exist_ok=False)
    shutil.copy2(fusion, backup_dir / "fusion.py")
    if advl_dst.exists():
        shutil.copy2(advl_dst, backup_dir / "advl.py")

    if MARKER in source:
        shutil.copy2(advl_src, advl_dst)
        print("ADVL_PATCH_ALREADY_PRESENT=True")
        print(f"BACKUP_DIR={backup_dir}")
        return backup_dir

    func = next(
        (n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == "create_thesis"),
        None,
    )
    if func is None or not func.body:
        fail("create_thesis() not found in fusion.py")

    lines = source.splitlines()

    # Insert import safely after a module docstring and all __future__ imports.
    insert_import_at = _import_insert_index(tree, lines)
    lines.insert(insert_import_at, IMPORT_LINE)

    # AST line numbers refer to original source. One import line was inserted.
    func_shift = 1 if insert_import_at < func.lineno else 0
    first_body_line = func.body[0].lineno - 1 + func_shift
    body_block = [
        "    advl = get_advl_feature()  # ABUTRON_ADVL_V1",
        "    try:",
        "        if isinstance(f.metadata, dict):",
        "            f.metadata[\"advl\"] = advl.as_dict()",
        "    except Exception:",
        "        pass",
    ]
    for offset, line in enumerate(body_block):
        lines.insert(first_body_line + offset, line)

    # Locate the existing score clamp only inside create_thesis.
    shifted_end = func.end_lineno + func_shift + len(body_block)
    clamp_index = None
    for i in range(first_body_line + len(body_block), min(len(lines), shifted_end + 2)):
        compact = "".join(lines[i].split())
        if compact.startswith("score=max(-1.0,min(1.0,float(score)))") or compact.startswith(
            "score=max(-1,min(1,float(score)))"
        ):
            clamp_index = i
            break
    if clamp_index is None:
        fail("Expected create_thesis score clamp was not found; no production patch was written.")

    blend_block = [
        "    score, advl_applied = blend_advl_confirmation(score, advl, mode)  # ABUTRON_ADVL_V1",
        "    if advl_applied:",
        "        comps.append(advl.signal)",
    ]
    for offset, line in enumerate(blend_block):
        lines.insert(clamp_index + offset, line)

    patched = "\n".join(lines) + ("\n" if source.endswith("\n") else "")
    try:
        ast.parse(patched)
    except SyntaxError as exc:
        fail(f"Patched fusion.py would not parse: {exc}")

    # Write module first, production Fusion last. Fusion is never written if the
    # prospective source cannot be parsed.
    shutil.copy2(advl_src, advl_dst)
    fusion.write_text(patched, encoding="utf-8")

    print("ADVL_PATCHED=True")
    print(f"FUSION={fusion}")
    print(f"ADVL_MODULE={advl_dst}")
    print(f"BACKUP_DIR={backup_dir}")
    return backup_dir


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python patch_fusion.py C:\\Abutron\\TradingPlatformV4")
    patch(Path(sys.argv[1]))
