from abutron.models import BotTier
from abutron.strategies.base import StrategyEngine, StrategyPolicy

class MasterEngine(StrategyEngine):
    tier=BotTier.MASTER
    name="master-v4-mtf-capital"
    def policy(self, profile, thesis):
        return StrategyPolicy(
            tier=self.tier,name=self.name,primary_tf=profile.primary_tf,
            context_tfs=tuple(profile.context_tfs),max_positions=profile.max_positions,
            cooldown_seconds=profile.cooldown_seconds,burst_positions=1,
            allow_reentry=False,min_confidence=profile.min_confidence,
            thesis_direction=thesis.direction)
