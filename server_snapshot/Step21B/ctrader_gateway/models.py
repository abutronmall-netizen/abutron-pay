from pydantic import BaseModel, Field

class MarketOrderRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=128)
    ctid_account_id: int = Field(gt=0)
    symbol_id: int = Field(gt=0)
    side: str = Field(pattern='^(BUY|SELL)$')
    # cTrader Open API protocol volume is 0.01 of a unit; core adapter must convert explicitly.
    protocol_volume: int = Field(gt=0)
    stop_loss: float | None = None
    take_profit: float | None = None
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
    stop_loss: float | None = None
    take_profit: float | None = None
    idempotency_key: str = Field(min_length=8, max_length=50)
    command_timestamp: int
