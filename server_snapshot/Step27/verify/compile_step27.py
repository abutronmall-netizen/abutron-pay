from pathlib import Path
import py_compile
root=Path(r"C:\Abutron\TradingPlatformV4")
for rel in (
    "abutron/step27_models.py",
    "abutron/step27_service.py",
    "abutron/step27_api.py",
    "abutron/api.py",
):
    py_compile.compile(str(root/rel),doraise=True)
print("STEP27_COMPILE=PASS")
