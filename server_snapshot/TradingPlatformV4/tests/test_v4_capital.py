from abutron.models import *
from abutron.capital import make_order_plan

def test_capital_never_forces_minimum_lot_over_budget():
    thesis=Thesis(symbol='XAUUSD',direction=Direction.BUY,confidence=90,score=.8,valid=True,reason='OK',regime='TRENDING',evidence={})
    f=FeatureVector(trend=.5,htf_trend=.5,momentum=.5,rsi=.1,structure=.5,liquidity=.2,fvg=.1,order_block=.1,displacement=.2,premium_discount=0,volatility_quality=.8,regime_score=.5,regime='TRENDING',atr=100.0,metadata={})
    a=AccountState(equity=20,balance=20,daily_pnl=0,open_risk=0,license_active=True,positions_total=0)
    b=BrokerContext(symbol='XAUUSD',bid=2000,ask=2000.2,point=.01,tick_size=.01,tick_value=1,volume_min=.01,volume_max=100,volume_step=.01,spread_points=20)
    r=RiskDecision(approved=True,reason='APPROVED',max_risk_amount=.4)
    plan=make_order_plan(thesis,f,a,b,r,1,tier=BotTier.FLIPPER)
    assert plan is None
