from abutron.advl import blend_advl_confirmation, get_advl_feature  # ABUTRON_ADVL_V1
import math
from abutron.models import CoreMode,Direction,FeatureVector,KronosSignal,Thesis

W={"k":0.34,"t":0.10,"h":0.12,"m":0.06,"r":0.04,"s":0.09,"l":0.07,"f":0.04,"o":0.04,"d":0.04,"p":0.02,"g":0.04}

def _conf(score,agreement,vq):
    base=100.0*(1.0-math.exp(-2.25*abs(score)))
    return max(0.0,min(100.0,base*(0.70+0.20*agreement+0.10*vq)))

def create_thesis(symbol,k,f,mode,min_confidence):
    advl = get_advl_feature()  # ABUTRON_ADVL_V1
    try:
        if isinstance(f.metadata, dict):
            f.metadata["advl"] = advl.as_dict()
    except Exception:
        pass
    inst=.15*f.trend+.18*f.htf_trend+.08*f.momentum+.05*f.rsi+.16*f.structure+.12*f.liquidity+.08*f.fvg+.07*f.order_block+.06*f.displacement+.02*f.premium_discount+.03*f.regime_score
    if mode==CoreMode.KRONOS:
        score=k.score; comps=[k.score]
    elif mode==CoreMode.INSTITUTIONAL:
        score=inst; comps=[f.trend,f.htf_trend,f.structure,f.liquidity,f.momentum]
    else:
        score=W["k"]*k.score+W["t"]*f.trend+W["h"]*f.htf_trend+W["m"]*f.momentum+W["r"]*f.rsi+W["s"]*f.structure+W["l"]*f.liquidity+W["f"]*f.fvg+W["o"]*f.order_block+W["d"]*f.displacement+W["p"]*f.premium_discount+W["g"]*f.regime_score
        comps=[k.score,f.trend,f.htf_trend,f.structure,f.liquidity,f.momentum]
    score, advl_applied = blend_advl_confirmation(score, advl, mode)  # ABUTRON_ADVL_V1
    if advl_applied:
        comps.append(advl.signal)
    score=max(-1.0,min(1.0,float(score)))
    sign=1 if score>0 else (-1 if score<0 else 0)
    active=[x for x in comps if abs(x)>=0.10]
    agreeing=sum(1 for x in active if (1 if x>0 else -1)==sign)
    agreement=agreeing/max(len(active),1) if sign else 0.0
    confidence=_conf(score,agreement,f.volatility_quality)
    hard_flip=(score>0 and f.htf_trend<-0.75) or (score<0 and f.htf_trend>0.75)
    if hard_flip:
        return Thesis(symbol=symbol,direction=Direction.HOLD,confidence=confidence,score=score,
            valid=False,reason="HTF_HARD_FLIP",regime=f.regime,
            evidence={"kronos":k.score,"htf_trend":f.htf_trend,"agreement":agreement})
    if confidence<min_confidence:
        direction=Direction.HOLD; valid=False; reason="CONFIDENCE_BELOW_THRESHOLD"
    else:
        direction=Direction.BUY if score>0 else Direction.SELL
        valid=True; reason="FUSION_APPROVED" if mode==CoreMode.FUSION else f"{mode.value}_APPROVED"
    return Thesis(symbol=symbol,direction=direction,confidence=confidence,score=score,valid=valid,
        reason=reason,regime=f.regime,evidence={"kronos":k.score,"trend":f.trend,
        "htf_trend":f.htf_trend,"momentum":f.momentum,"structure":f.structure,
        "liquidity":f.liquidity,"fvg":f.fvg,"order_block":f.order_block,
        "regime":f.regime_score,"agreement":agreement})
