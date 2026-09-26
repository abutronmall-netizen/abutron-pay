import numpy as np
from abutron.models import MarketSnapshot
from abutron.features.technical import atr

def institutional(snapshot:MarketSnapshot,lookback=20)->dict:
    b=snapshot.candles
    zero={"structure":0.0,"liquidity":0.0,"fvg":0.0,"order_block":0.0,
          "displacement":0.0,"premium_discount":0.0,
          "bos_up":False,"bos_down":False,"sweep_high":False,"sweep_low":False}
    if len(b)<lookback+3: return zero
    last=b[-1]
    prev=b[-(lookback+1):-1]
    ph=max(x.high for x in prev); pl=min(x.low for x in prev)
    bos_up=last.close>ph; bos_down=last.close<pl
    structure=1.0 if bos_up else (-1.0 if bos_down else 0.0)
    sweep_high=last.high>ph and last.close<ph
    sweep_low=last.low<pl and last.close>pl
    liquidity=-1.0 if sweep_high else (1.0 if sweep_low else 0.0)
    a3,c=b[-3],b[-1]
    bull_fvg=c.low>a3.high; bear_fvg=c.high<a3.low
    fvg=1.0 if bull_fvg else (-1.0 if bear_fvg else 0.0)
    prevbar=b[-2]
    ob=1.0 if (bos_up and prevbar.close<prevbar.open) else (-1.0 if (bos_down and prevbar.close>prevbar.open) else 0.0)
    av=atr(snapshot) or 1e-12
    displacement=float(np.clip((last.close-last.open)/(av*1.5),-1,1))
    midpoint=(ph+pl)/2.0; half=max((ph-pl)/2.0,1e-12)
    premium_discount=float(np.clip((midpoint-last.close)/half,-1,1))
    highs=np.array([x.high for x in b[-8:]],dtype=float)
    lows=np.array([x.low for x in b[-8:]],dtype=float)
    hh=np.mean(np.diff(highs)>0); hl=np.mean(np.diff(lows)>0)
    lh=np.mean(np.diff(highs)<0); ll=np.mean(np.diff(lows)<0)
    structural_bias=float(np.clip((hh+hl-lh-ll)/2.0,-1,1))
    if structure==0.0: structure=structural_bias
    return {"structure":structure,"liquidity":liquidity,"fvg":fvg,"order_block":ob,
            "displacement":displacement,"premium_discount":premium_discount,
            "bos_up":bos_up,"bos_down":bos_down,"sweep_high":sweep_high,"sweep_low":sweep_low}
