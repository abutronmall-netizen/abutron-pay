from pathlib import Path
import ast
import shutil
import sys
import time

root = Path(sys.argv[1] if len(sys.argv) > 1 else r"C:\Abutron\TradingPlatformV4")
api = root / "abutron" / "api.py"
if not api.exists():
    raise SystemExit(f"API_NOT_FOUND={api}")

# Existing production api.py can contain a UTF-8 BOM.
# utf-8-sig safely removes it when present and behaves like utf-8 otherwise.
text = api.read_bytes().decode("utf-8-sig")

import_marker = "from abutron.step26a_api import router as step26a_router"
include_marker = "app.include_router(step26a_router)"

# Idempotent resume support.
if import_marker in text and include_marker in text:
    ast.parse(text)
    print("STEP26A_API_ALREADY_PATCHED=True")
    print("STEP26A_API_PATCH=PASS")
    raise SystemExit(0)

anchors = [
    "from abutron.security import hash_password,verify_password,issue_token,current_user,require_admin",
    'app=FastAPI(title="ABUTRON TRADING PLATFORM",version=__version__,lifespan=lifespan)',
]
for anchor in anchors:
    if anchor not in text:
        print(f"STEP26A_PATCH_ABORT=MISSING_ANCHOR:{anchor}")
        raise SystemExit(2)

backup = api.with_name(f"api.py.pre_step26a_{time.strftime('%Y%m%d-%H%M%S')}")
shutil.copy2(api, backup)
print(f"STEP26A_API_BACKUP={backup}")

text = text.replace(
    anchors[0],
    anchors[0] + "\n" + import_marker,
    1,
)
text = text.replace(
    anchors[1],
    anchors[1] + "\n" + include_marker,
    1,
)

# Validate before changing production source.
ast.parse(text)

# Normalize the updated file to UTF-8 without BOM.
api.write_text(text, encoding="utf-8")

# Validate the exact production file after writing.
ast.parse(api.read_text(encoding="utf-8"))
print("STEP26A_API_BOM_SAFE=PASS")
print("STEP26A_API_PATCH=PASS")
