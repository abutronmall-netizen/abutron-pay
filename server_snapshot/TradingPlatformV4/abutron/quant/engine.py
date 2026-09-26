from __future__ import annotations
from dataclasses import asdict, dataclass
from enum import StrEnum
from math import erf, exp, isfinite, log, pi, sqrt
import os
from statistics import fmean, median

EPS=1e-12
Z95=1.6448536269514722

class QuantMode(StrEnum):
    OFF="OFF"
    SHADOW="SHADOW"

@dataclass(frozen=True,slots=True)
class QuantResult:
    mode: QuantMode
    ok: bool
    reason: str
    telemetry: dict
    tier: str|None=None
    def to_dict(self):
        return {
            "version":"1.0.0",
            "mode":self.mode.value,
            "ok":self.ok,
            "reason":self.reason,
            "tier":self.tier,
            "telemetry":self.telemetry,
            "authoritative_for_trading":False,
        }
    def stage_detail(self):
        regime=self.telemetry.get("regime",{}).get("label")
        net=self.telemetry.get("economics",{}).get("net_expected_edge")
        net_text="n/a" if net is None else f"{net:.8f}"
        return f"mode={self.mode.value} status={'OK' if self.ok else 'WARN'} regime={regime} net_edge={net_text} authority=OBSERVE_ONLY"

def _finite(values,name="values"):
    x=[float(v) for v in values]
    if not x or any(not isfinite(v) for v in x):
        raise ValueError(f"{name} must contain finite values")
    return x

def arithmetic_returns(prices):
    p=_finite(prices,"prices")
    if len(p)<2 or any(v<=0 for v in p): raise ValueError("at least two positive prices are required")
    return [(p[i]/p[i-1])-1.0 for i in range(1,len(p))]

def log_returns(prices):
    p=_finite(prices,"prices")
    if len(p)<2 or any(v<=0 for v in p): raise ValueError("at least two positive prices are required")
    return [log(p[i]/p[i-1]) for i in range(1,len(p))]

def sample_variance(x):
    x=_finite(x)
    if len(x)<2:return 0.0
    m=fmean(x)
    return sum((v-m)**2 for v in x)/(len(x)-1)

def _z(value,x):
    x=_finite(x); s=sqrt(max(sample_variance(x),0))
    return 0.0 if s<=EPS else (float(value)-fmean(x))/s

def _mad(x):
    x=_finite(x); m=median(x)
    return median([abs(v-m) for v in x])

def _robust_z(value,x):
    x=_finite(x); m=median(x); mad=_mad(x)
    return 0.0 if mad<=EPS else 0.67448975*(float(value)-m)/mad

def _percentile(value,x):
    x=sorted(_finite(x))
    return (sum(v<value for v in x)+0.5*sum(v==value for v in x))/len(x)

def _skew(x):
    x=_finite(x); n=len(x)
    if n<3:return 0.0
    m=fmean(x); s2=sample_variance(x)
    if s2<=EPS:return 0.0
    s=sqrt(s2)
    return (n/((n-1)*(n-2)))*sum(((v-m)/s)**3 for v in x)

def _kurt(x):
    x=_finite(x); n=len(x)
    if n<4:return 0.0
    m=fmean(x); s2=sample_variance(x)
    if s2<=EPS:return 0.0
    s=sqrt(s2); s4=sum(((v-m)/s)**4 for v in x)
    return n*(n+1)/((n-1)*(n-2)*(n-3))*s4 - 3*(n-1)**2/((n-2)*(n-3))

def _autocorr(x):
    x=_finite(x)
    if len(x)<3:return 0.0
    a,b=x[:-1],x[1:]; ma,mb=fmean(a),fmean(b)
    num=sum((u-ma)*(v-mb) for u,v in zip(a,b))
    den=sqrt(sum((u-ma)**2 for u in a)*sum((v-mb)**2 for v in b))
    return 0.0 if den<=EPS else max(-1,min(1,num/den))

def _ewma_var(x,decay=0.94):
    x=_finite(x)
    v=x[0]*x[0]
    for z in x[1:]: v=decay*v+(1-decay)*z*z
    return v

def _semivar(x,down=True):
    x=_finite(x); s=[v*v for v in x if (v<0 if down else v>0)]
    return 0.0 if not s else sum(s)/len(x)

def _vol_ratio(x,short=20,long=60):
    x=_finite(x); a=x[-min(short,len(x)):]; b=x[-min(long,len(x)):]
    av=sqrt(max(sample_variance(a),0)); bv=sqrt(max(sample_variance(b),0))
    return 1.0 if bv<=EPS else av/bv

def _entropy(x):
    x=_finite(x); counts=(sum(v>0 for v in x),sum(v<0 for v in x),sum(v==0 for v in x))
    h=0.0
    for c in counts:
        if c:
            p=c/len(x); h-=p*log(p)
    return h/log(3.0)

def _variance_ratio(x,q=5):
    x=_finite(x)
    if len(x)<max(2*q,10):return 1.0
    one=sample_variance(x)
    if one<=EPS:return 1.0
    agg=[sum(x[i:i+q]) for i in range(0,len(x)-q+1,q)]
    return 1.0 if len(agg)<2 else sample_variance(agg)/(q*one)

def _trend_persistence(x,window=30):
    x=_finite(x)[-window:]
    return abs(sum(v>0 for v in x)-sum(v<0 for v in x))/len(x)

def _vol_cluster(x,window=40):
    y=[abs(v) for v in _finite(x)[-window:]]
    if len(y)<3:return 0.0
    a,b=y[:-1],y[1:]; ma,mb=fmean(a),fmean(b)
    num=sum((u-ma)*(v-mb) for u,v in zip(a,b))
    den=sqrt(sum((u-ma)**2 for u in a)*sum((v-mb)**2 for v in b))
    return 0.0 if den<=EPS else max(-1,min(1,num/den))

def _regime(ent,vr,persist,volr):
    if volr>=1.5:return "HIGH_VOLATILITY"
    if persist>=0.45 and vr>1.05:return "TRENDING"
    if vr<0.90:return "MEAN_REVERTING"
    if ent>=0.85:return "NOISY"
    return "MIXED"

def _normal_cdf(z): return 0.5*(1+erf(z/sqrt(2)))

def _forecast(expected,vol):
    if expected is None:return {"expected_return":None,"normalized_expected_return":None,"directional_strength_proxy":None,"uncertainty_proxy":None}
    z=float(expected)/max(vol,EPS)
    strength=2*abs(_normal_cdf(abs(z))-0.5)
    return {"expected_return":float(expected),"normalized_expected_return":z,"directional_strength_proxy":strength,"uncertainty_proxy":max(0,min(1,1-strength))}

def _costs(bid,ask,slip_bps,comm_bps):
    bid=float(bid or 0); ask=float(ask or 0)
    spread=0.0
    if bid>0 and ask>=bid:
        mid=(bid+ask)/2
        spread=0.0 if mid<=0 else (ask-bid)/mid
    slip=max(0,float(slip_bps))/10000
    comm=max(0,float(comm_bps))/10000
    return spread,slip,comm,spread+slip+comm

def _var95(mu,sigma): return max(0.0,-(mu-Z95*max(sigma,0.0)))
def _es95(mu,sigma):
    sigma=max(sigma,0.0)
    if sigma<=EPS:return max(0.0,-mu)
    phi=(1/sqrt(2*pi))*exp(-0.5*Z95*Z95)
    return max(0.0,-(mu-sigma*phi/0.05))

class QuantEngine:
    def __init__(self,mode=QuantMode.SHADOW,slippage_bps=0.0,commission_bps=0.0):
        self.mode=mode
        self.slippage_bps=max(0,float(slippage_bps))
        self.commission_bps=max(0,float(commission_bps))
    @classmethod
    def from_env(cls):
        raw=os.getenv("ABUTRON_QUANT_MODE","SHADOW").strip().upper()
        # Step 23Q deliberately supports only OFF and SHADOW.
        mode=QuantMode.OFF if raw=="OFF" else QuantMode.SHADOW
        return cls(mode,os.getenv("ABUTRON_QUANT_SLIPPAGE_BPS","0"),os.getenv("ABUTRON_QUANT_COMMISSION_BPS","0"))
    def evaluate(self,snapshot,broker=None,kronos=None,tier=None):
        tier_value=getattr(tier,"value",tier)
        if self.mode is QuantMode.OFF:
            return QuantResult(self.mode,True,"QUANT_OFF",{},tier_value)
        try:
            prices=[float(c.close) for c in snapshot.candles]
            if len(prices)<16: raise ValueError("at least 16 closes are required")
            ar=arithmetic_returns(prices); lr=log_returns(prices)
            var=sample_variance(lr); vol=sqrt(max(var,0)); rv=sum(v*v for v in lr)
            down=_semivar(lr,True); up=_semivar(lr,False); ew=sqrt(_ewma_var(lr)); volr=_vol_ratio(lr)
            ent=_entropy(lr); vr=_variance_ratio(lr); persist=_trend_persistence(lr); cluster=_vol_cluster(lr)
            label=_regime(ent,vr,persist,volr)
            expected=getattr(kronos,"expected_return",None) if kronos is not None else None
            fc=_forecast(expected,max(ew,vol))
            bid=getattr(broker,"bid",0.0) if broker is not None else 0.0
            ask=getattr(broker,"ask",0.0) if broker is not None else 0.0
            spread,slip,comm,total=_costs(bid,ask,self.slippage_bps,self.commission_bps)
            gross=None if expected is None else abs(float(expected)); net=None if gross is None else gross-total
            telemetry={
              "returns":{"arithmetic_return":ar[-1],"log_return":lr[-1],"mean_log_return":fmean(lr),"variance":var,"volatility":vol,
                         "skewness":_skew(lr),"excess_kurtosis":_kurt(lr),"zscore":_z(lr[-1],lr),"robust_zscore":_robust_z(lr[-1],lr),
                         "percentile_rank":_percentile(lr[-1],lr),"lag1_autocorrelation":_autocorr(lr),"sample_size":len(lr)},
              "volatility":{"realized_variance":rv,"realized_volatility":sqrt(rv),"ewma_volatility":ew,"downside_semivariance":down,
                            "upside_semivariance":up,"downside_deviation":sqrt(down),"volatility_ratio":volr},
              "regime":{"entropy":ent,"variance_ratio":vr,"trend_persistence":persist,"volatility_cluster_score":cluster,"label":label},
              "forecast":fc,
              "economics":{"spread_return_cost":spread,"slippage_return_cost":slip,"commission_return_cost":comm,"total_return_cost":total,
                           "gross_expected_edge":gross,"net_expected_edge":net,"positive_net_edge":None if net is None else net>0},
              "risk_math":{"var_95_return":_var95(fmean(lr),vol),"expected_shortfall_95_return":_es95(fmean(lr),vol),
                           "downside_to_total_vol_ratio":0.0 if vol<=EPS else sqrt(down)/vol,
                           "tail_warning":_kurt(lr)>3 or abs(_skew(lr))>1.5}
            }
            return QuantResult(self.mode,True,"QUANT_SHADOW_OBSERVE_ONLY",telemetry,tier_value)
        except Exception as exc:
            # A QME failure is visible but must not break the existing trading pipeline in SHADOW.
            return QuantResult(self.mode,False,f"{type(exc).__name__}:{exc}",{},tier_value)
