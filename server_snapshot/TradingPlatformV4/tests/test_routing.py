from abutron.profiles import route_equity
from abutron.models import BotTier
def test_equity_routing():
    assert route_equity(19.99)==BotTier.INELIGIBLE
    assert route_equity(20)==BotTier.FLIPPER
    assert route_equity(3000)==BotTier.FLIPPER
    assert route_equity(3000.01)==BotTier.SCALPER
    assert route_equity(5000)==BotTier.SCALPER
    assert route_equity(5000.01)==BotTier.MASTER
    assert route_equity(10000)==BotTier.MASTER
    assert route_equity(10000.01)==BotTier.MANUAL_REVIEW
