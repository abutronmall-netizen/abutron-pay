import time
from abutron.config import settings
from abutron.models import RiskDecision,Direction,BotTier
from abutron.profiles import route_equity,profile_for

class RiskEngine:
    def evaluate(self,thesis,account,broker,market,tier=None):
        if not account.license_active:
            return RiskDecision(approved=False,reason="LICENSE_INACTIVE")
        tier=tier or route_equity(account.equity)
        if tier==BotTier.INELIGIBLE:
            return RiskDecision(approved=False,reason="EQUITY_BELOW_MINIMUM")
        if tier==BotTier.MANUAL_REVIEW:
            return RiskDecision(approved=False,reason="EQUITY_REQUIRES_MANUAL_REVIEW")
        if not thesis.valid or thesis.direction==Direction.HOLD:
            return RiskDecision(approved=False,reason=thesis.reason)
        age=max(0,int(time.time())-market.primary.received_ts)
        if age>settings.max_market_age_seconds:
            return RiskDecision(approved=False,reason="STALE_MARKET_DATA")
        if broker.spread_points>settings.max_spread_points:
            return RiskDecision(approved=False,reason="SPREAD_TOO_WIDE")
        if broker.positions_on_symbol>=settings.max_positions_per_symbol:
            return RiskDecision(approved=False,reason="MAX_SYMBOL_POSITIONS")
        if tier in {BotTier.FLIPPER,BotTier.SCALPER,BotTier.MASTER} and broker.positions_on_symbol>=profile_for(tier).max_positions:
            return RiskDecision(approved=False,reason="STRATEGY_MAX_POSITIONS")
        if account.balance>0:
            dd=max(0.0,(account.balance-account.equity)/account.balance*100.0)
            if dd>=settings.emergency_drawdown_pct:
                return RiskDecision(approved=False,reason="EMERGENCY_DRAWDOWN_GUARD")
        daily_limit=account.balance*(settings.max_daily_loss_pct/100.0)
        if account.daily_pnl<=-daily_limit:
            return RiskDecision(approved=False,reason="MAX_DAILY_LOSS")
        open_limit=account.equity*(settings.max_open_risk_pct/100.0)
        if account.open_risk>=open_limit:
            return RiskDecision(approved=False,reason="MAX_OPEN_RISK")
        return RiskDecision(approved=True,reason="APPROVED",max_risk_amount=max(0.0,open_limit-account.open_risk))
