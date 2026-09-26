from pathlib import Path
import py_compile

root = Path(r"C:\Abutron\TradingPlatformV4")
targets = list((root / "abutron" / "quant").glob("*.py")) + [root / "abutron" / "service.py"]
for target in targets:
    py_compile.compile(str(target), doraise=True)
print("STEP23Q_COMPILE=PASS")
