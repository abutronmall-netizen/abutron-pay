from abutron.models import BotTier
from abutron.strategies.base import StrategyEngine, StrategyPolicy

class FlipperEngine(StrategyEngine):
    tier=BotTier.FLIPPER
    name="flipper-v4-adaptive-directional"
    def policy(self, profile, thesis):
        return StrategyPolicy(
            tier=self.tier,name=self.name,primary_tf=profile.primary_tf,
            context_tfs=tuple(profile.context_tfs),max_positions=profile.max_positions,
            cooldown_seconds=profile.cooldown_seconds,burst_positions=min(2,profile.max_positions),
            allow_reentry=True,min_confidence=profile.min_confidence,
            thesis_direction=thesis.direction)
