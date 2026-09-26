import numpy as np
from abutron.models import MarketSnapshot

def ema(x,span):
    a=2.0/(span+1.0)
    y=float(x[0])
    for v in x[1:]:
        y=a*float(v)+(1-a)*y
    return y

def atr(snapshot:MarketSnapshot,period=14)->float:
    b=snapshot.candles
    if len(b)<period+1: return 0.0
    tr=[]
    for i in range(1,len(b)):
        tr.append(max(b[i].high-b[i].low,abs(b[i].high-b[i-1].close),abs(b[i].low-b[i-1].close)))
    return float(np.mean(tr[-period:]))

def rsi(snapshot:MarketSnapshot,period=14)->float:
    c=np.array([x.close for x in snapshot.candles],dtype=float)
    if len(c)<period+1: return 0.0
    d=np.diff(c[-(period+1):])
    gain=np.mean(np.clip(d,0,None))
    loss=np.mean(np.clip(-d,0,None))
    if loss<=1e-12: return 1.0 if gain>0 else 0.0
    val=100-(100/(1+gain/loss))
    return float(np.clip((val-50)/50,-1,1))

def technical(snapshot:MarketSnapshot)->dict:
    c=np.array([x.close for x in snapshot.candles],dtype=float)
    a=atr(snapshot)
    if len(c)<30 or a<=0:
        return {"trend":0.0,"momentum":0.0,"rsi":0.0,"atr":a,"volatility_quality":0.0}
    ef,es=ema(c[-30:],8),ema(c[-30:],21)
    trend=float(np.clip((ef-es)/(a*1.5),-1,1))
    momentum=float(np.clip((c[-1]-c[-6])/(a*2.0),-1,1))
    ret=np.diff(np.log(np.maximum(c[-30:],1e-12)))
    vol=float(np.std(ret))
    med=float(np.median(np.abs(ret)))+1e-12
    vq=float(np.clip(vol/(med*3.0),0,1))
    return {"trend":trend,"momentum":momentum,"rsi":rsi(snapshot),"atr":a,"volatility_quality":vq}
