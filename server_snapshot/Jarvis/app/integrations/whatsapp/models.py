from enum import Enum
from pydantic import BaseModel, Field

class AlertSeverity(str, Enum):
    INFO="INFO"; WARNING="WARNING"; CRITICAL="CRITICAL"; EMERGENCY="EMERGENCY"

class CallState(str, Enum):
    DISABLED="DISABLED"; APPROVAL_REQUIRED="APPROVAL_REQUIRED"; REQUESTED="REQUESTED"
    RINGING="RINGING"; CONNECTED="CONNECTED"; ENDED="ENDED"; FAILED="FAILED"

class CallRequest(BaseModel):
    operator_wa_id: str = Field(pattern=r"^[0-9]{8,20}$")
    reason: str
    severity: AlertSeverity
    incident_id: str
    approved: bool = False
