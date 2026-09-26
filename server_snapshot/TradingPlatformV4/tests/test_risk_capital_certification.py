import time

import pytest

from abutron.capital import make_order_plan
from abutron.config import settings
from abutron.models import (
    AccountState,
    BotTier,
    BrokerContext,
    Candle,
    Direction,
    FeatureVector,
    MarketBundle,
    MarketSnapshot,
    Thesis,
)
from abutron.profiles import profile_for, route_equity
from abutron.risk import RiskEngine


# ============================================================
# HELPERS
# ============================================================

def thesis(
    direction=Direction.BUY,
    *,
    valid=True,
    reason="CERTIFICATION",
):
    return Thesis(
        symbol="BTCUSD",
        direction=direction,
        confidence=99.0,
        score=0.99,
        valid=valid,
        reason=reason,
        regime="TRENDING",
        evidence={},
    )


def features(atr=1.0):
    return FeatureVector(
        trend=0.8,
        htf_trend=0.8,
        momentum=0.8,
        rsi=0.5,
        structure=0.8,
        liquidity=0.5,
        fvg=0.5,
        order_block=0.5,
        displacement=0.7,
        premium_discount=0.0,
        volatility_quality=0.8,
        regime_score=0.8,
        regime="TRENDING",
        atr=atr,
        metadata={},
    )


def market(received_offset=0):
    now=int(time.time())

    bars=[
        Candle(
            ts=now,
            open=100.0,
            high=101.0,
            low=99.0,
            close=100.5,
        )
        for _ in range(64)
    ]

    return MarketBundle(
        primary=MarketSnapshot(
            symbol="BTCUSD",
            timeframe="M1",
            candles=bars,
            received_ts=now+received_offset,
        )
    )


def account(
    equity,
    *,
    balance=None,
    daily_pnl=0.0,
    open_risk=0.0,
    license_active=True,
    positions_total=0,
):
    return AccountState(
        equity=float(equity),
        balance=float(
            equity
            if balance is None
            else balance
        ),
        daily_pnl=float(daily_pnl),
        open_risk=float(open_risk),
        license_active=license_active,
        positions_total=positions_total,
    )


def broker(
    *,
    spread=10.0,
    positions=0,
    volume_min=0.01,
    volume_max=100.0,
    volume_step=0.01,
):
    return BrokerContext(
        symbol="BTCUSD",
        bid=100.0,
        ask=100.1,
        point=0.01,
        tick_size=0.01,
        tick_value=1.0,
        volume_min=volume_min,
        volume_max=volume_max,
        volume_step=volume_step,
        spread_points=spread,
        positions_on_symbol=positions,
    )


def approved_chain(
    equity,
    tier,
    *,
    atr=1.0,
    direction=Direction.BUY,
    open_risk=0.0,
):
    acc=account(
        equity,
        open_risk=open_risk,
    )

    br=broker()

    th=thesis(
        direction
    )

    mkt=market()

    risk=RiskEngine().evaluate(
        th,
        acc,
        br,
        mkt,
        tier=tier,
    )

    assert risk.approved is True
    assert risk.reason == "APPROVED"

    plan=make_order_plan(
        th,
        features(atr),
        acc,
        br,
        risk,
        int(time.time()),
        tier=tier,
    )

    return acc,br,th,risk,plan


# ============================================================
# RISK ENGINE -- REPRESENTATIVE EQUITIES
# ============================================================

@pytest.mark.parametrize(
    "equity,tier",
    [
        (1000.0, BotTier.FLIPPER),
        (4000.0, BotTier.SCALPER),
        (7000.0, BotTier.MASTER),
    ],
)
def test_risk_approves_each_execution_tier(
    equity,
    tier,
):
    acc=account(equity)

    risk=RiskEngine().evaluate(
        thesis(),
        acc,
        broker(),
        market(),
        tier=tier,
    )

    assert risk.approved is True
    assert risk.reason == "APPROVED"

    expected=(
        equity
        * settings.max_open_risk_pct
        / 100.0
    )

    assert risk.max_risk_amount == pytest.approx(
        expected
    )


# ============================================================
# CAPITAL -- TIER RISK PERCENTAGES + GEOMETRY
# ============================================================

@pytest.mark.parametrize(
    "equity,tier,expected_risk_pct",
    [
        (
            1000.0,
            BotTier.FLIPPER,
            0.50,
        ),
        (
            4000.0,
            BotTier.SCALPER,
            0.40,
        ),
        (
            7000.0,
            BotTier.MASTER,
            0.35,
        ),
    ],
)
def test_capital_respects_tier_risk_budget_and_geometry(
    equity,
    tier,
    expected_risk_pct,
):
    (
        acc,
        br,
        th,
        risk,
        plan,
    )=approved_chain(
        equity,
        tier,
        atr=1.0,
    )

    assert plan is not None

    p=profile_for(tier)

    assert (
        p.risk_pct
        == pytest.approx(
            expected_risk_pct
        )
    )

    authorized_target=min(
        equity
        * expected_risk_pct
        / 100.0,
        risk.max_risk_amount,
    )

    assert (
        plan.risk_amount
        <= authorized_target
        + 1e-9
    )

    assert (
        plan.risk_amount
        <= risk.max_risk_amount
        + 1e-9
    )

    assert plan.tier == tier

    assert (
        plan.strategy_profile
        == p.name
    )

    assert (
        plan.entry
        == pytest.approx(
            br.ask
        )
    )

    assert (
        plan.sl
        == pytest.approx(
            br.ask
            - p.sl_atr
        )
    )

    assert (
        plan.tp
        == pytest.approx(
            br.ask
            + p.tp_atr
        )
    )


# ============================================================
# ROUTER -> RISK -> CAPITAL BOUNDARIES
# ============================================================

@pytest.mark.parametrize(
    "equity,expected_tier",
    [
        (
            20.00,
            BotTier.FLIPPER,
        ),
        (
            3000.00,
            BotTier.FLIPPER,
        ),
        (
            3000.01,
            BotTier.SCALPER,
        ),
        (
            5000.00,
            BotTier.SCALPER,
        ),
        (
            5000.01,
            BotTier.MASTER,
        ),
        (
            10000.00,
            BotTier.MASTER,
        ),
    ],
)
def test_boundary_equity_routes_through_risk_and_capital(
    equity,
    expected_tier,
):
    tier=route_equity(
        equity
    )

    assert tier == expected_tier

    acc=account(equity)
    br=broker()

    th=thesis()

    risk=RiskEngine().evaluate(
        th,
        acc,
        br,
        market(),
        tier=tier,
    )

    assert risk.approved is True

    plan=make_order_plan(
        th,
        features(0.01),
        acc,
        br,
        risk,
        int(time.time()),
        tier=tier,
    )

    assert plan is not None
    assert plan.tier == expected_tier

    p=profile_for(
        expected_tier
    )

    risk_target=min(
        equity
        * p.risk_pct
        / 100.0,
        risk.max_risk_amount,
    )

    assert (
        plan.risk_amount
        <= risk_target
        + 1e-9
    )


# ============================================================
# MINIMUM LOT MUST NEVER BE FORCED OVER BUDGET
# ============================================================

@pytest.mark.parametrize(
    "equity,tier",
    [
        (
            1000.0,
            BotTier.FLIPPER,
        ),
        (
            4000.0,
            BotTier.SCALPER,
        ),
        (
            7000.0,
            BotTier.MASTER,
        ),
    ],
)
def test_minimum_lot_is_not_forced_over_budget(
    equity,
    tier,
):
    acc=account(equity)
    br=broker(
        volume_min=0.01
    )

    th=thesis()

    risk=RiskEngine().evaluate(
        th,
        acc,
        br,
        market(),
        tier=tier,
    )

    assert risk.approved is True

    # Huge ATR makes even 0.01 lot exceed
    # the authorized per-trade budget.
    plan=make_order_plan(
        th,
        features(100.0),
        acc,
        br,
        risk,
        int(time.time()),
        tier=tier,
    )

    assert plan is None


# ============================================================
# REMAINING PORTFOLIO-RISK CAP
# ============================================================

def test_remaining_open_risk_caps_new_position():
    equity=4000.0
    tier=BotTier.SCALPER

    # 2% portfolio limit = $80.
    # $78 already exposed -> only $2 remains.
    acc=account(
        equity,
        open_risk=78.0,
    )

    br=broker()

    risk=RiskEngine().evaluate(
        thesis(),
        acc,
        br,
        market(),
        tier=tier,
    )

    assert risk.approved is True

    assert (
        risk.max_risk_amount
        == pytest.approx(
            2.0
        )
    )

    plan=make_order_plan(
        thesis(),
        features(0.10),
        acc,
        br,
        risk,
        int(time.time()),
        tier=tier,
    )

    assert plan is not None

    assert (
        plan.risk_amount
        <= 2.0
        + 1e-9
    )


# ============================================================
# LOT STEP MUST FLOOR, NEVER ROUND UP
# ============================================================

def test_volume_step_is_floored_never_rounded_up():
    (
        acc,
        br,
        th,
        risk,
        plan,
    )=approved_chain(
        1000.0,
        BotTier.FLIPPER,
        atr=0.37,
    )

    assert plan is not None

    # risk_target = $5
    # stop distance = 0.4995
    # risk/lot = 49.95
    # raw volume ~= 0.1001001
    # 0.01 broker step must floor to 0.10.
    assert (
        plan.volume
        == pytest.approx(
            0.10
        )
    )

    assert (
        plan.risk_amount
        <= 5.0
        + 1e-9
    )


# ============================================================
# SELL GEOMETRY
# ============================================================

def test_master_sell_geometry():
    (
        acc,
        br,
        th,
        risk,
        plan,
    )=approved_chain(
        7000.0,
        BotTier.MASTER,
        atr=1.0,
        direction=Direction.SELL,
    )

    assert plan is not None

    assert (
        plan.entry
        == pytest.approx(
            br.bid
        )
    )

    assert (
        plan.sl
        == pytest.approx(
            br.bid + 1.50
        )
    )

    assert (
        plan.tp
        == pytest.approx(
            br.bid - 2.25
        )
    )


# ============================================================
# RISK ENGINE FAIL-CLOSED GUARDS
# ============================================================

@pytest.mark.parametrize(
    "case,expected",
    [
        (
            "license",
            "LICENSE_INACTIVE",
        ),
        (
            "below_minimum",
            "EQUITY_BELOW_MINIMUM",
        ),
        (
            "manual_review",
            "EQUITY_REQUIRES_MANUAL_REVIEW",
        ),
        (
            "stale",
            "STALE_MARKET_DATA",
        ),
        (
            "spread",
            "SPREAD_TOO_WIDE",
        ),
        (
            "global_positions",
            "MAX_SYMBOL_POSITIONS",
        ),
        (
            "strategy_positions",
            "STRATEGY_MAX_POSITIONS",
        ),
        (
            "drawdown",
            "EMERGENCY_DRAWDOWN_GUARD",
        ),
        (
            "daily_loss",
            "MAX_DAILY_LOSS",
        ),
        (
            "open_risk",
            "MAX_OPEN_RISK",
        ),
    ],
)
def test_risk_guards_fail_closed(
    case,
    expected,
):
    equity=1000.0
    balance=1000.0
    license_active=True
    daily_pnl=0.0
    open_risk=0.0
    spread=10.0
    positions=0
    received_offset=0

    if case == "license":
        license_active=False

    elif case == "below_minimum":
        equity=19.99
        balance=19.99

    elif case == "manual_review":
        equity=10000.01
        balance=10000.01

    elif case == "stale":
        received_offset=(
            -settings.max_market_age_seconds
            - 1
        )

    elif case == "spread":
        spread=(
            settings.max_spread_points
            + 1
        )

    elif case == "global_positions":
        positions=(
            settings.max_positions_per_symbol
        )

    elif case == "strategy_positions":
        positions=(
            profile_for(
                BotTier.FLIPPER
            ).max_positions
        )

    elif case == "drawdown":
        equity=919.0
        balance=1000.0

    elif case == "daily_loss":
        daily_pnl=-30.0

    elif case == "open_risk":
        open_risk=20.0

    acc=account(
        equity,
        balance=balance,
        daily_pnl=daily_pnl,
        open_risk=open_risk,
        license_active=license_active,
    )

    br=broker(
        spread=spread,
        positions=positions,
    )

    risk=RiskEngine().evaluate(
        thesis(),
        acc,
        br,
        market(
            received_offset
        ),
    )

    assert risk.approved is False
    assert risk.reason == expected