import json
from datetime import datetime,timezone
from pathlib import Path
from app.core.settings import settings
def audit(event,payload):
 p=Path(settings.jarvis_audit_log);p.parent.mkdir(parents=True,exist_ok=True)
 with p.open("a",encoding="utf8") as f:f.write(json.dumps({"ts":datetime.now(timezone.utc).isoformat(),"event":event,"payload":payload},default=str)+"\n")
