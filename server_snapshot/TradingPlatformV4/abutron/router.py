from __future__ import annotations
from dataclasses import dataclass
from abutron.models import BotTier
from abutron.profiles import route_equity

@dataclass(frozen=True)
class RouteResult:
    requested: BotTier
    selected: BotTier
    locked: bool
    reason: str


def route_with_position_lock(equity: float, current_tier: BotTier | None, open_positions: int) -> RouteResult:
    """Route by equity, but never switch engines while positions are open.

    This prevents strategy ownership changes mid-trade. If there are open positions and
    a currently assigned executable tier exists, that tier remains active until flat.
    """
    requested = route_equity(equity)
    executable = {BotTier.FLIPPER, BotTier.SCALPER, BotTier.MASTER}
    if open_positions > 0 and current_tier in executable and requested != current_tier:
        return RouteResult(requested=requested, selected=current_tier, locked=True,
                           reason="OPEN_POSITIONS_TIER_LOCK")
    return RouteResult(requested=requested, selected=requested, locked=False,
                       reason="EQUITY_ROUTE")
