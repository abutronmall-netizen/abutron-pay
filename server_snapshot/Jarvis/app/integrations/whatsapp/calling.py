"""
WhatsApp Business Calling control adapter.

This module deliberately separates:
1. Meta call-control/webhook signalling.
2. Real-time media transport (WebRTC/SIP).
3. Jarvis authorization.

No arbitrary call is placed by an LLM. Business-initiated calls require:
- Meta calling capability enabled for the WABA/number
- configured media gateway
- approved/eligible operator
- Abutron Policy Engine approval
"""
from app.core.settings import settings
from app.core.policy import PolicyEngine, Decision
from app.core.audit import audit
from .models import CallRequest, CallState

policy = PolicyEngine()

class WhatsAppCallingService:
    def status(self):
        return {
            "enabled": settings.whatsapp_calling_enabled,
            "transport": "META_WHATSAPP_BUSINESS_CALLING",
            "media_gateway_required": True,
        }

    def request(self, req: CallRequest):
        if not settings.whatsapp_calling_enabled:
            return {"state": CallState.DISABLED, "reason": "Calling not provisioned in Meta yet."}
        decision = policy.decide("initiate_whatsapp_call")
        if decision == Decision.DENY:
            raise PermissionError("Calling denied by policy.")
        if decision == Decision.APPROVAL and not req.approved:
            audit("call_approval_required", req.model_dump())
            return {"state": CallState.APPROVAL_REQUIRED, "incident_id": req.incident_id}

        # Transport execution is intentionally blocked until Meta phone-number
        # calling provisioning and the selected WebRTC/SIP gateway are configured.
        audit("call_transport_not_configured", req.model_dump())
        return {
            "state": CallState.FAILED,
            "reason": "Meta calling enabled in Jarvis, but media/signalling adapter is not configured.",
        }

calling_service = WhatsAppCallingService()
