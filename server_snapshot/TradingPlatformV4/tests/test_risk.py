import time
from abutron.models import *
from abutron.risk import RiskEngine
def test_daily_loss_rejects():
    thesis=Thesis(symbol="EURUSD",direction=Direction.BUY,confidence=90,score=.8,valid=True,reason="OK",regime="TRENDING",evidence={})
    acc=AccountState(equity=1000,balance=1000,daily_pnl=-40,license_active=True)
    broker=BrokerContext(symbol="EURUSD",bid=1,ask=1.0001,point=.00001,tick_size=.00001,tick_value=1,
        volume_min=.01,volume_max=100,volume_step=.01,spread_points=10)
    bars=[Candle(ts=int(time.time()),open=1,high=1.1,low=.9,close=1.01) for _ in range(64)]
    bundle=MarketBundle(primary=MarketSnapshot(symbol="EURUSD",timeframe="M1",candles=bars,received_ts=int(time.time())))
    r=RiskEngine().evaluate(thesis,acc,broker,bundle)
    assert not r.approved
    assert r.reason=="MAX_DAILY_LOSS"
