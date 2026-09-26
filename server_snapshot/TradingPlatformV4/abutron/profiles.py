from abutron.config import settings
from abutron.models import BotTier, ExecutionProfile

def route_equity(equity:float)->BotTier:
    if equity < 20.0: return BotTier.INELIGIBLE
    if equity <= 3000.0: return BotTier.FLIPPER
    if equity <= 5000.0: return BotTier.SCALPER
    if equity <= 10000.0: return BotTier.MASTER
    return BotTier.MANUAL_REVIEW

def profile_for(tier:BotTier)->ExecutionProfile:
    if tier==BotTier.FLIPPER:
        return ExecutionProfile(
            tier=tier,name="flipper-v4-adaptive-directional",
            primary_tf="M1",context_tfs=["M5","M15"],
            min_confidence=settings.min_confidence_flipper,
            risk_pct=settings.flipper_risk_pct,sl_atr=1.35,tp_atr=1.10,
            max_positions=2,cooldown_seconds=60)
    if tier==BotTier.SCALPER:
        return ExecutionProfile(
            tier=tier,name="scalper-v4-precision-sniper",
            primary_tf="M1",context_tfs=["M5","M15"],
            min_confidence=settings.min_confidence_scalper,
            risk_pct=settings.scalper_risk_pct,sl_atr=1.20,tp_atr=1.50,
            max_positions=2,cooldown_seconds=180)
    if tier==BotTier.MASTER:
        return ExecutionProfile(
            tier=tier,name="master-v4-mtf-capital",
            primary_tf="M15",context_tfs=["H1","H4"],
            min_confidence=settings.min_confidence_master,
            risk_pct=settings.master_risk_pct,sl_atr=1.50,tp_atr=2.25,
            max_positions=1,cooldown_seconds=900)
    raise ValueError(f"No executable profile for {tier}")
