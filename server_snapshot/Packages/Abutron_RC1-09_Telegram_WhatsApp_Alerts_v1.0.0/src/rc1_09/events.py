from __future__ import annotations
from typing import Iterable

def normalize_collection(obj) -> list[dict]:
    if obj is None:
        return []
    if isinstance(obj, dict) and "value" in obj:
        v=obj["value"]
        return list(v) if isinstance(v,list) else []
    if isinstance(obj,list):
        return list(obj)
    return []

def incident_event(i:dict,status:str)->dict:
    iid=str(i.get("id","UNKNOWN"))
    sev=str(i.get("severity","INFO")).upper()
    summary=str(i.get("summary","No summary")).strip()
    if status=="OPEN":
        return {
            "event_key":f"incident:{iid}:OPEN",
            "kind":"INCIDENT_OPEN",
            "severity":sev,
            "title":f"Incident OPEN — {i.get('check_name','unknown')}",
            "body":summary,
            "reference_id":iid,
        }
    return {
        "event_key":f"incident:{iid}:RECOVERED",
        "kind":"INCIDENT_RECOVERED",
        "severity":sev,
        "title":f"Incident RECOVERED — {i.get('check_name','unknown')}",
        "body":summary,
        "reference_id":iid,
    }

def approval_event(a:dict)->dict:
    aid=str(a.get("id","UNKNOWN"))
    return {
        "event_key":f"approval:{aid}:PENDING",
        "kind":"APPROVAL_PENDING",
        "severity":"HIGH",
        "title":"Human approval required",
        "body":f"Action: {a.get('action_type','UNKNOWN')} | Incident: {a.get('incident_id','UNKNOWN')}",
        "reference_id":aid,
    }

def render_plain(event:dict)->str:
    prefix={
        "CRITICAL":"🚨",
        "HIGH":"⚠️",
        "MEDIUM":"ℹ️",
        "LOW":"ℹ️",
        "INFO":"ℹ️",
    }.get(str(event.get("severity","INFO")).upper(),"ℹ️")
    title=str(event.get("title","Abutron alert"))
    body=str(event.get("body",""))
    ref=str(event.get("reference_id",""))
    return f"{prefix} ABUTRON JARVIS\n{title}\nSeverity: {event.get('severity','INFO')}\n{body}\nRef: {ref}"[:4000]
