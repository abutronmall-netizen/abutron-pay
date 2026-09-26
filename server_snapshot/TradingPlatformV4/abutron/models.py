from __future__ import annotations
from enum import Enum
from typing import Dict, List
from pydantic import BaseModel, Field

class Direction(str, Enum):
    BUY="BUY"
    SELL="SELL"
    HOLD="HOLD"

class CoreMode(str, Enum):
    KRONOS="KRONOS"
    INSTITUTIONAL="INSTITUTIONAL"
    FUSION="FUSION"

class BotTier(str, Enum):
    INELIGIBLE="INELIGIBLE"
    FLIPPER="FLIPPER"
    SCALPER="SCALPER"
    MASTER="MASTER"
    MANUAL_REVIEW="MANUAL_REVIEW"

class Candle(BaseModel):
    ts:int
    open:float
    high:float
    low:float
    close:float
    volume:float=0.0

class MarketSnapshot(BaseModel):
    symbol:str
    timeframe:str
    candles:List[Candle]
    spread_points:float=0.0
    received_ts:int

class MarketBundle(BaseModel):
    primary:MarketSnapshot
    contexts:Dict[str,MarketSnapshot]={}

class KronosSignal(BaseModel):
    score:float=Field(ge=-1,le=1)
    direction:Direction
    expected_return:float
    normalized_move:float
    predicted_close:float
    model_version:str
    device:str

class FeatureVector(BaseModel):
    trend:float=Field(ge=-1,le=1)
    htf_trend:float=Field(ge=-1,le=1)
    momentum:float=Field(ge=-1,le=1)
    rsi:float=Field(ge=-1,le=1)
    structure:float=Field(ge=-1,le=1)
    liquidity:float=Field(ge=-1,le=1)
    fvg:float=Field(ge=-1,le=1)
    order_block:float=Field(ge=-1,le=1)
    displacement:float=Field(ge=-1,le=1)
    premium_discount:float=Field(ge=-1,le=1)
    volatility_quality:float=Field(ge=0,le=1)
    regime_score:float=Field(ge=-1,le=1)
    regime:str
    atr:float
    metadata:Dict[str,float|str|bool]={}

class Thesis(BaseModel):
    symbol:str
    direction:Direction
    confidence:float=Field(ge=0,le=100)
    score:float=Field(ge=-1,le=1)
    valid:bool
    reason:str
    regime:str
    evidence:Dict[str,float|str|bool]

class AccountState(BaseModel):
    equity:float
    balance:float
    daily_pnl:float=0.0
    open_risk:float=0.0
    license_active:bool=True
    positions_total:int=0
    login:str=""
    server:str=""
    currency:str=""

class BrokerContext(BaseModel):
    symbol:str
    bid:float
    ask:float
    point:float
    tick_size:float
    tick_value:float
    volume_min:float
    volume_max:float
    volume_step:float
    spread_points:float
    positions_on_symbol:int=0

class RiskDecision(BaseModel):
    approved:bool
    reason:str
    max_risk_amount:float=0.0

class ExecutionProfile(BaseModel):
    tier:BotTier
    name:str
    primary_tf:str
    context_tfs:List[str]
    min_confidence:float
    risk_pct:float
    sl_atr:float
    tp_atr:float
    max_positions:int
    cooldown_seconds:int

class OrderPlan(BaseModel):
    symbol:str
    direction:Direction
    tier:BotTier
    strategy_profile:str
    volume:float
    entry:float
    sl:float
    tp:float
    risk_amount:float
    confidence:float
    idempotency_key:str
    thesis_reason:str

class PipelineStage(BaseModel):
    name:str
    status:str
    detail:str=""
    duration_ms:float=0.0

class EquityRoute(BaseModel):
    requested:BotTier
    selected:BotTier
    locked:bool=False
    reason:str="EQUITY_ROUTE"

class StrategyPolicyModel(BaseModel):
    tier:BotTier
    name:str
    primary_tf:str
    context_tfs:List[str]
    max_positions:int
    cooldown_seconds:int
    burst_positions:int
    allow_reentry:bool
    min_confidence:float
    thesis_direction:Direction

class PipelineResult(BaseModel):
    version:str
    symbol:str
    decision:Direction
    mode:CoreMode
    route:EquityRoute
    strategy:StrategyPolicyModel|None=None
    kronos:KronosSignal
    features:FeatureVector
    thesis:Thesis
    risk:RiskDecision
    plan:OrderPlan|None=None
    execution:dict|None=None
    stages:List[PipelineStage]=[]
