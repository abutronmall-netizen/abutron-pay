from abutron.models import BotTier
from abutron.strategies.flipper import FlipperEngine
from abutron.strategies.scalper import ScalperEngine
from abutron.strategies.master import MasterEngine

ENGINES={
    BotTier.FLIPPER: FlipperEngine(),
    BotTier.SCALPER: ScalperEngine(),
    BotTier.MASTER: MasterEngine(),
}

def engine_for(tier: BotTier):
    if tier not in ENGINES:
        raise ValueError(f"No execution engine for {tier}")
    return ENGINES[tier]
