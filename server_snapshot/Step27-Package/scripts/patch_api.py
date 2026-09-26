from pathlib import Path
import ast
import shutil
import sys
import time

root = Path(sys.argv[1] if len(sys.argv) > 1 else r"C:\Abutron\TradingPlatformV4")
api = root / "abutron" / "api.py"
if not api.exists():
    raise SystemExit(f"API_NOT_FOUND={api}")

text = api.read_bytes().decode("utf-8-sig")
import_marker = "from abutron.step27_api import router as step27_router"
include_marker = "app.include_router(step27_router)"

if import_marker in text and include_marker in text:
    ast.parse(text)
    print("STEP27_API_ALREADY_PATCHED=True")
    print("STEP27_API_PATCH=PASS")
    raise SystemExit(0)

security_anchor = "from abutron.security import hash_password,verify_password,issue_token,current_user,require_admin"
app_anchor = 'app=FastAPI(title="ABUTRON TRADING PLATFORM",version=__version__,lifespan=lifespan)'

for anchor in (security_anchor, app_anchor):
    if anchor not in text:
        print(f"STEP27_PATCH_ABORT=MISSING_ANCHOR:{anchor}")
        raise SystemExit(2)

backup = api.with_name(f"api.py.pre_step27_{time.strftime('%Y%m%d-%H%M%S')}")
shutil.copy2(api, backup)
print(f"STEP27_API_BACKUP={backup}")

text = text.replace(security_anchor, security_anchor + "\n" + import_marker, 1)
text = text.replace(app_anchor, app_anchor + "\n" + include_marker, 1)

ast.parse(text)
api.write_text(text, encoding="utf-8")
ast.parse(api.read_text(encoding="utf-8"))

print("STEP27_API_PATCH=PASS")
