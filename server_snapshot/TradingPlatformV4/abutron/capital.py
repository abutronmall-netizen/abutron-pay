import math,hashlib
from abutron.models import Direction
from abutron.profiles import profile_for,route_equity

def _floor_step(x,step):
    return x if step<=0 else math.floor(x/step+1e-12)*step

def make_order_plan(thesis,features,account,broker,risk,bar_ts,tier=None):
    if not risk.approved: return None
    tier=tier or route_equity(account.equity)
    profile=profile_for(tier)
    if broker.tick_size<=0 or broker.tick_value<=0 or features.atr<=0: return None
    entry=broker.ask if thesis.direction==Direction.BUY else broker.bid
    stop_dist=features.atr*profile.sl_atr
    tp_dist=features.atr*profile.tp_atr
    risk_target=min(account.equity*(profile.risk_pct/100.0),risk.max_risk_amount)
    risk_per_lot=(stop_dist/broker.tick_size)*broker.tick_value
    if risk_per_lot<=0: return None
    raw_vol=risk_target/risk_per_lot
    vol=_floor_step(raw_vol,broker.volume_step)
    vol=max(0.0,min(vol,broker.volume_max))
    # Never force the broker minimum lot when it exceeds the authorized risk budget.
    if vol+1e-12<broker.volume_min: return None
    actual_risk=(stop_dist/broker.tick_size)*broker.tick_value*vol
    if actual_risk>risk.max_risk_amount+1e-9: return None
    sl=entry-stop_dist if thesis.direction==Direction.BUY else entry+stop_dist
    tp=entry+tp_dist if thesis.direction==Direction.BUY else entry-tp_dist
    from abutron.models import OrderPlan
    idem=hashlib.sha256(f"{thesis.symbol}|{thesis.direction.value}|{bar_ts}|{profile.name}".encode()).hexdigest()[:32]
    return OrderPlan(symbol=thesis.symbol,direction=thesis.direction,tier=tier,
        strategy_profile=profile.name,volume=round(vol,8),entry=entry,sl=sl,tp=tp,
        risk_amount=actual_risk,confidence=thesis.confidence,idempotency_key=idem,
        thesis_reason=thesis.reason)
