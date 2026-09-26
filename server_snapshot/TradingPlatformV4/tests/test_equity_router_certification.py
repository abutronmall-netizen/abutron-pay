from types import SimpleNamespace

import pytest

from abutron.models import BotTier, Direction
from abutron.profiles import route_equity, profile_for
from abutron.router import route_with_position_lock
from abutron.strategies.scalper import ScalperEngine
from abutron.strategies.master import MasterEngine


# ============================================================
# EQUITY ROUTER EXACT BOUNDARIES
# ============================================================

@pytest.mark.parametrize(
    "equity,expected",
    [
        (0.00, BotTier.INELIGIBLE),
        (19.99, BotTier.INELIGIBLE),

        (20.00, BotTier.FLIPPER),
        (3000.00, BotTier.FLIPPER),

        (3000.01, BotTier.SCALPER),
        (3001.00, BotTier.SCALPER),
        (5000.00, BotTier.SCALPER),

        (5000.01, BotTier.MASTER),
        (5001.00, BotTier.MASTER),
        (10000.00, BotTier.MASTER),

        (10000.01, BotTier.MANUAL_REVIEW),
        (25000.00, BotTier.MANUAL_REVIEW),
    ],
)
def test_equity_router_boundaries(
    equity,
    expected
):
    assert route_equity(
        equity
    ) == expected


# ============================================================
# POSITION / STICKY TIER LOCK
# ============================================================

def test_flipper_remains_locked_when_equity_enters_scalper():
    result=route_with_position_lock(
        equity=3001.00,
        current_tier=BotTier.FLIPPER,
        open_positions=1,
    )

    assert (
        result.requested
        == BotTier.SCALPER
    )

    assert (
        result.selected
        == BotTier.FLIPPER
    )

    assert result.locked is True

    assert (
        result.reason
        == "OPEN_POSITIONS_TIER_LOCK"
    )


def test_scalper_remains_locked_when_equity_enters_master():
    result=route_with_position_lock(
        equity=5001.00,
        current_tier=BotTier.SCALPER,
        open_positions=1,
    )

    assert (
        result.requested
        == BotTier.MASTER
    )

    assert (
        result.selected
        == BotTier.SCALPER
    )

    assert result.locked is True

    assert (
        result.reason
        == "OPEN_POSITIONS_TIER_LOCK"
    )


def test_master_remains_locked_if_equity_exceeds_supported_range():
    result=route_with_position_lock(
        equity=10000.01,
        current_tier=BotTier.MASTER,
        open_positions=1,
    )

    assert (
        result.requested
        == BotTier.MANUAL_REVIEW
    )

    assert (
        result.selected
        == BotTier.MASTER
    )

    assert result.locked is True


def test_router_switches_when_account_is_flat():
    result=route_with_position_lock(
        equity=3001.00,
        current_tier=BotTier.FLIPPER,
        open_positions=0,
    )

    assert (
        result.requested
        == BotTier.SCALPER
    )

    assert (
        result.selected
        == BotTier.SCALPER
    )

    assert result.locked is False

    assert (
        result.reason
        == "EQUITY_ROUTE"
    )


# ============================================================
# SCALPER EXECUTION PROFILE
# ============================================================

def test_scalper_profile_contract():
    p=profile_for(
        BotTier.SCALPER
    )

    assert p.tier == BotTier.SCALPER

    assert (
        p.name
        == "scalper-v4-precision-sniper"
    )

    assert p.primary_tf == "M1"

    assert tuple(
        p.context_tfs
    ) == (
        "M5",
        "M15",
    )

    assert p.sl_atr == 1.20
    assert p.tp_atr == 1.50

    assert p.max_positions == 2

    assert (
        p.cooldown_seconds
        == 180
    )


# ============================================================
# MASTER EXECUTION PROFILE
# ============================================================

def test_master_profile_contract():
    p=profile_for(
        BotTier.MASTER
    )

    assert p.tier == BotTier.MASTER

    assert (
        p.name
        == "master-v4-mtf-capital"
    )

    assert p.primary_tf == "M15"

    assert tuple(
        p.context_tfs
    ) == (
        "H1",
        "H4",
    )

    assert p.sl_atr == 1.50
    assert p.tp_atr == 2.25

    assert p.max_positions == 1

    assert (
        p.cooldown_seconds
        == 900
    )


# ============================================================
# SCALPER STRATEGY POLICY
# ============================================================

def test_scalper_strategy_policy():
    profile=profile_for(
        BotTier.SCALPER
    )

    thesis=SimpleNamespace(
        direction=Direction.BUY
    )

    policy=ScalperEngine().policy(
        profile,
        thesis,
    )

    assert (
        policy.tier
        == BotTier.SCALPER
    )

    assert (
        policy.name
        == "scalper-v4-precision-sniper"
    )

    assert (
        policy.primary_tf
        == "M1"
    )

    assert (
        tuple(policy.context_tfs)
        == ("M5","M15")
    )

    assert (
        policy.max_positions
        == 2
    )

    assert (
        policy.cooldown_seconds
        == 180
    )

    assert (
        policy.burst_positions
        == 1
    )

    assert (
        policy.allow_reentry
        is False
    )

    assert (
        policy.thesis_direction
        == Direction.BUY
    )


# ============================================================
# MASTER STRATEGY POLICY
# ============================================================

def test_master_strategy_policy():
    profile=profile_for(
        BotTier.MASTER
    )

    thesis=SimpleNamespace(
        direction=Direction.SELL
    )

    policy=MasterEngine().policy(
        profile,
        thesis,
    )

    assert (
        policy.tier
        == BotTier.MASTER
    )

    assert (
        policy.name
        == "master-v4-mtf-capital"
    )

    assert (
        policy.primary_tf
        == "M15"
    )

    assert (
        tuple(policy.context_tfs)
        == ("H1","H4")
    )

    assert (
        policy.max_positions
        == 1
    )

    assert (
        policy.cooldown_seconds
        == 900
    )

    assert (
        policy.burst_positions
        == 1
    )

    assert (
        policy.allow_reentry
        is False
    )

    assert (
        policy.thesis_direction
        == Direction.SELL
    )