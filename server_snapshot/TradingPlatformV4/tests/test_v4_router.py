from abutron.models import BotTier
from abutron.router import route_with_position_lock
from abutron.strategies import engine_for
from abutron.profiles import profile_for
from abutron.models import Thesis,Direction

def test_router_locks_during_open_positions():
    r=route_with_position_lock(3500,BotTier.FLIPPER,1)
    assert r.requested==BotTier.SCALPER
    assert r.selected==BotTier.FLIPPER
    assert r.locked

def test_router_changes_when_flat():
    r=route_with_position_lock(3500,BotTier.FLIPPER,0)
    assert r.selected==BotTier.SCALPER
    assert not r.locked

def test_all_three_strategy_engines_exist():
    t=Thesis(symbol='XAUUSD',direction=Direction.BUY,confidence=90,score=.8,valid=True,reason='OK',regime='TRENDING',evidence={})
    for tier in (BotTier.FLIPPER,BotTier.SCALPER,BotTier.MASTER):
        p=engine_for(tier).policy(profile_for(tier),t)
        assert p.tier==tier
        assert p.thesis_direction==Direction.BUY
