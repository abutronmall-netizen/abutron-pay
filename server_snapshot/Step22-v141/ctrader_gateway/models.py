from pydantic import BaseModel, Field

class MarketOrderRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=128)
    ctid_account_id: int = Field(gt=0)
    symbol_id: int = Field(gt=0)
    side: str = Field(pattern='^(BUY|SELL)$')
    # cTrader Open API protocol volume is 0.01 of a unit; core adapter must convert explicitly.
    protocol_volume: int = Field(gt=0)
    # Absolute SL/TP are NOT sent on MARKET orders. cTrader requires relative protection for MARKET.
    relative_stop_loss: int | None = Field(default=None, gt=0)
    relative_take_profit: int | None = Field(default=None, gt=0)
    idempotency_key: str = Field(min_length=8, max_length=50)
    command_timestamp: int

class ClosePositionRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=128)
    ctid_account_id: int = Field(gt=0)
    position_id: int = Field(gt=0)
    protocol_volume: int = Field(gt=0)
    idempotency_key: str = Field(min_length=8, max_length=50)
    command_timestamp: int

class AmendPositionRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=128)
    ctid_account_id: int = Field(gt=0)
    position_id: int = Field(gt=0)
    # Absolute SL/TP are NOT sent on MARKET orders. cTrader requires relative protection for MARKET.
    relative_stop_loss: int | None = Field(default=None, gt=0)
    relative_take_profit: int | None = Field(default=None, gt=0)
    idempotency_key: str = Field(min_length=8, max_length=50)
    command_timestamp: int


class Step21CPreflightRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=128)
    ctid_account_id: int = Field(gt=0)
    symbol: str = Field(default='XAUUSD', pattern='^XAUUSD$')

class Step21CLifecycleRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=128)
    ctid_account_id: int = Field(gt=0)
    symbol_id: int = Field(gt=0)
    side: str = Field(pattern='^(BUY|SELL)$')
    protocol_volume: int = Field(gt=0)
    planned_entry: float = Field(gt=0)
    stop_loss: float = Field(gt=0)
    take_profit: float = Field(gt=0)
    tier: str = Field(pattern='^(FLIPPER|SCALPER|MASTER)$')
    strategy_profile: str = Field(min_length=3, max_length=128)
    risk_approved: bool
    risk_reason: str = Field(min_length=1, max_length=128)
    risk_amount: float = Field(ge=0)
    idempotency_key: str = Field(min_length=8, max_length=50)
    command_timestamp: int
