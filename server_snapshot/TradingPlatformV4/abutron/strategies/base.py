from __future__ import annotations
from dataclasses import dataclass
from abutron.models import BotTier, Direction, ExecutionProfile, Thesis

@dataclass(frozen=True)
class StrategyPolicy:
    tier: BotTier
    name: str
    primary_tf: str
    context_tfs: tuple[str, ...]
    max_positions: int
    cooldown_seconds: int
    burst_positions: int
    allow_reentry: bool
    min_confidence: float
    thesis_direction: Direction

class StrategyEngine:
    tier: BotTier
    name: str
    def policy(self, profile: ExecutionProfile, thesis: Thesis) -> StrategyPolicy:
        raise NotImplementedError
