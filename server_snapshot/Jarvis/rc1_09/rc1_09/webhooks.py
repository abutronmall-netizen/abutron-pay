from __future__ import annotations
import hashlib,hmac,json

def valid_meta_signature(raw:bytes,header:str,app_secret:str)->bool:
    if not app_secret or not header or not header.startswith("sha256="):
        return False
    expected="sha256="+hmac.new(app_secret.encode("utf-8"),raw,hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected,header)

def extract_whatsapp_statuses(payload:dict)->list[dict]:
    out=[]
    for entry in payload.get("entry",[]) or []:
        for change in entry.get("changes",[]) or []:
            value=change.get("value") or {}
            for s in value.get("statuses",[]) or []:
                mid=s.get("id")
                status=s.get("status")
                if mid and status:
                    errors=s.get("errors") or []
                    err=json.dumps(errors,separators=(",",":")) if errors else None
                    out.append({"id":str(mid),"status":str(status),"error":err})
    return out
