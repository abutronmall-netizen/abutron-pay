import numpy as np
from abutron.models import MarketSnapshot

def regime(snapshot:MarketSnapshot)->dict:
    c=np.array([x.close for x in snapshot.candles],dtype=float)
    if len(c)<40: return {"regime":"UNKNOWN","regime_score":0.0,"efficiency":0.0,"vol_ratio":0.0}
    path=np.sum(np.abs(np.diff(c[-20:])))
    efficiency=float(abs(c[-1]-c[-20])/max(path,1e-12))
    ret=np.diff(np.log(np.maximum(c[-40:],1e-12)))
    recent=float(np.std(ret[-10:])); base=float(np.std(ret))+1e-12
    vol_ratio=recent/base
    drift=float(np.mean(ret[-10:]))
    score=float(np.clip(drift/base,-1,1))
    if vol_ratio>1.60: name="HIGH_VOL"
    elif efficiency>0.48: name="TRENDING"
    elif efficiency<0.22: name="RANGING"
    else: name="TRANSITION"
    return {"regime":name,"regime_score":score,"efficiency":efficiency,"vol_ratio":float(vol_ratio)}
