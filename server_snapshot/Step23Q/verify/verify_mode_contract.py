from abutron.quant.engine import QuantMode
modes = {x.value for x in QuantMode}
assert modes == {"OFF", "SHADOW"}, modes
print("STEP23Q_MODE_CONTRACT=PASS")
