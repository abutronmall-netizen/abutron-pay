import numpy as np
from abutron.models import MarketBundle, FeatureVector
from abutron.features.technical import technical
from abutron.features.institutional import institutional
from abutron.features.regime import regime

def build_features(bundle:MarketBundle)->FeatureVector:
    t=technical(bundle.primary); i=institutional(bundle.primary); r=regime(bundle.primary)
    h=[technical(s)["trend"] for s in bundle.contexts.values()]
    htf=float(np.mean(h)) if h else t["trend"]
    return FeatureVector(
        trend=t["trend"],htf_trend=float(np.clip(htf,-1,1)),momentum=t["momentum"],rsi=t["rsi"],
        structure=i["structure"],liquidity=i["liquidity"],fvg=i["fvg"],order_block=i["order_block"],
        displacement=i["displacement"],premium_discount=i["premium_discount"],
        volatility_quality=t["volatility_quality"],regime_score=r["regime_score"],regime=r["regime"],
        atr=t["atr"],metadata={"bos_up":i["bos_up"],"bos_down":i["bos_down"],
        "sweep_high":i["sweep_high"],"sweep_low":i["sweep_low"],
        "efficiency":r["efficiency"],"vol_ratio":r["vol_ratio"]})
