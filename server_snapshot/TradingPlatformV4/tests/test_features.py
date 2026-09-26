import time
from abutron.models import Candle,MarketSnapshot
from abutron.features.institutional import institutional
def test_institutional_is_causal_and_runs():
    bars=[]
    p=100.0
    for i in range(40):
        bars.append(Candle(ts=int(time.time())-60*(40-i),open=p,high=p+1,low=p-1,close=p+0.2,volume=100))
        p+=0.25
    s=MarketSnapshot(symbol="EURUSD",timeframe="M1",candles=bars,received_ts=int(time.time()))
    f=institutional(s)
    assert -1<=f["structure"]<=1
    assert "sweep_high" in f
