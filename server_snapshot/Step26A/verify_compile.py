from pathlib import Path
import py_compile
root=Path(r"C:\Abutron\TradingPlatformV4")
targets=[
    root/"abutron"/"step26a_models.py",
    root/"abutron"/"step26a_api.py",
    root/"abutron"/"api.py",
]
for t in targets:
    py_compile.compile(str(t),doraise=True)
print("STEP26A_COMPILE=PASS")
