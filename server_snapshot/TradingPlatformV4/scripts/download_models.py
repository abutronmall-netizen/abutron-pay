import os,sys
from pathlib import Path
repo=Path(os.getenv("ABUTRON_KRONOS_REPO","./vendor/Kronos")).resolve()
sys.path.insert(0,str(repo))
from model import Kronos,KronosTokenizer
tok=os.getenv("ABUTRON_KRONOS_TOKENIZER","NeoQuasar/Kronos-Tokenizer-base")
mdl=os.getenv("ABUTRON_KRONOS_MODEL","NeoQuasar/Kronos-small")
print("Verifying tokenizer:",tok)
KronosTokenizer.from_pretrained(tok)
print("Verifying predictor:",mdl)
Kronos.from_pretrained(mdl)
print("Kronos artifacts ready.")
