import math,os,unittest
from dataclasses import dataclass
from abutron.quant.engine import QuantEngine,QuantMode,arithmetic_returns,log_returns
from abutron.quant.portfolio import correlation_matrix
from abutron.quant.strategy_stats import summarize
@dataclass
class Candle: close:float
@dataclass
class Snapshot: candles:list
@dataclass
class Broker: bid:float;ask:float
@dataclass
class Kronos: expected_return:float
def snap(): return Snapshot([Candle(100+i*0.12+(0.05 if i%2 else -0.03)) for i in range(50)])
class Tests(unittest.TestCase):
    def test_returns(self):
        self.assertAlmostEqual(arithmetic_returns([100,101])[0],.01)
        self.assertAlmostEqual(log_returns([100,101])[0],math.log(1.01))
    def test_shadow_observe_only(self):
        r=QuantEngine().evaluate(snap(),Broker(105,105.1),Kronos(.002))
        self.assertTrue(r.ok);self.assertEqual(r.mode,QuantMode.SHADOW);self.assertFalse(r.to_dict()["authoritative_for_trading"])
        self.assertIn("economics",r.telemetry)
    def test_no_gate_mode(self): self.assertEqual({m.value for m in QuantMode},{"OFF","SHADOW"})
    def test_unknown_gate_env_falls_back_shadow(self):
        old=os.environ.get("ABUTRON_QUANT_MODE");os.environ["ABUTRON_QUANT_MODE"]="GATE"
        try:self.assertEqual(QuantEngine.from_env().mode,QuantMode.SHADOW)
        finally:
            if old is None:os.environ.pop("ABUTRON_QUANT_MODE",None)
            else:os.environ["ABUTRON_QUANT_MODE"]=old
    def test_short_data_nonfatal(self): self.assertFalse(QuantEngine().evaluate(Snapshot([Candle(1),Candle(2)])).ok)
    def test_correlation(self): self.assertAlmostEqual(correlation_matrix({"a":[1,2,3],"b":[2,4,6]})["a"]["b"],1.0)
    def test_strategy_stats(self): self.assertGreater(summarize([2,-1,3,-2,4]).expectancy,0)
if __name__=="__main__":unittest.main()
