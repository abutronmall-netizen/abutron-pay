import subprocess
from app.core.settings import settings
from app.core.policy import PolicyEngine,Decision
from app.core.audit import audit
P=PolicyEngine()
def send_whatsapp(message,target=None):
 if P.decide("send_incident_message")!=Decision.ALLOW:raise PermissionError
 dest=target or settings.hermes_whatsapp_target
 c=subprocess.run([settings.hermes_exe,"send","--to",dest,message],capture_output=True,text=True,timeout=60)
 audit("whatsapp_send",{"target":dest,"code":c.returncode})
 if c.returncode:raise RuntimeError(c.stderr)
 return c.stdout
def request_call():
 if not settings.whatsapp_calling_enabled:raise RuntimeError("Official WhatsApp calling not provisioned")
 return {"status":"APPROVAL_REQUIRED"}
