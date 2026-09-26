from app.integrations.whatsapp.calling import WhatsAppCallingService
from app.integrations.whatsapp.models import CallRequest, AlertSeverity, CallState

def test_calling_disabled_by_default():
    s=WhatsAppCallingService()
    r=s.request(CallRequest(operator_wa_id="27820000000",reason="test",severity=AlertSeverity.CRITICAL,incident_id="T1"))
    assert r["state"] == CallState.DISABLED
