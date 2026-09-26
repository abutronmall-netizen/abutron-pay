from .models import AlertSeverity, CallRequest
from .calling import calling_service
from app.integrations.hermes import send_whatsapp

def escalate(operator_wa_id: str, incident_id: str, severity: AlertSeverity, message: str):
    # Always message first so there is a written incident trail.
    msg_result = send_whatsapp(message)
    result = {"message": "SENT", "call": None}
    if severity in (AlertSeverity.CRITICAL, AlertSeverity.EMERGENCY):
        req = CallRequest(
            operator_wa_id=operator_wa_id,
            reason=message,
            severity=severity,
            incident_id=incident_id,
        )
        result["call"] = calling_service.request(req)
    return result
