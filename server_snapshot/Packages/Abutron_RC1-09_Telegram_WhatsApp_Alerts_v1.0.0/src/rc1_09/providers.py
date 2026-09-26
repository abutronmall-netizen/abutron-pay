from __future__ import annotations
from dataclasses import dataclass
import json, urllib.request, urllib.error, re

class ProviderError(RuntimeError):
    pass

def _post_json(url:str,payload:dict,headers:dict|None=None,timeout:int=20)->dict:
    data=json.dumps(payload).encode("utf-8")
    h={"Content-Type":"application/json"}
    if headers: h.update(headers)
    req=urllib.request.Request(url,data=data,headers=h,method="POST")
    try:
        with urllib.request.urlopen(req,timeout=timeout) as r:
            raw=r.read().decode("utf-8","replace")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body=e.read().decode("utf-8","replace")
        raise ProviderError(f"HTTP {e.code}: {body[:1000]}") from e
    except Exception as e:
        raise ProviderError(f"{type(e).__name__}: {e}") from e

@dataclass
class SendResult:
    provider_message_id: str|None

class TelegramProvider:
    def __init__(self,token:str,chat_id:str):
        if not re.fullmatch(r"-?\d+",chat_id or ""):
            raise ValueError("Telegram chat_id must be numeric")
        self.token=token
        self.chat_id=chat_id

    def send(self,text:str,event:dict)->SendResult:
        url=f"https://api.telegram.org/bot{self.token}/sendMessage"
        result=_post_json(url,{
            "chat_id":self.chat_id,
            "text":text[:4096],
            "disable_web_page_preview":True,
            "protect_content":True,
        })
        if not result.get("ok"):
            raise ProviderError(f"Telegram response not ok: {result}")
        mid=(result.get("result") or {}).get("message_id")
        return SendResult(str(mid) if mid is not None else None)

class WhatsAppProvider:
    def __init__(self,access_token:str,phone_number_id:str,recipient:str,graph_version:str,
                 mode:str="template",template_name:str="abutron_system_alert",template_language:str="en_US"):
        self.access_token=access_token
        self.phone_number_id=phone_number_id
        self.recipient=re.sub(r"\D","",recipient or "")
        self.graph_version=graph_version.strip().lstrip("/")
        self.mode=mode
        self.template_name=template_name
        self.template_language=template_language
        if not self.recipient:
            raise ValueError("WhatsApp recipient required")
        if not self.graph_version:
            raise ValueError("Meta Graph API version required")

    def send(self,text:str,event:dict)->SendResult:
        url=f"https://graph.facebook.com/{self.graph_version}/{self.phone_number_id}/messages"
        if self.mode=="text":
            payload={
                "messaging_product":"whatsapp",
                "to":self.recipient,
                "type":"text",
                "text":{"preview_url":False,"body":text[:4096]},
            }
        else:
            payload={
                "messaging_product":"whatsapp",
                "to":self.recipient,
                "type":"template",
                "template":{
                    "name":self.template_name,
                    "language":{"code":self.template_language},
                    "components":[{
                        "type":"body",
                        "parameters":[
                            {"type":"text","text":str(event.get("severity","INFO"))[:100]},
                            {"type":"text","text":str(event.get("title","Abutron alert"))[:500]},
                            {"type":"text","text":str(event.get("body",""))[:1000]},
                            {"type":"text","text":str(event.get("reference_id",""))[:200]},
                        ]
                    }]
                }
            }
        result=_post_json(url,payload,headers={"Authorization":f"Bearer {self.access_token}"})
        messages=result.get("messages") or []
        if not messages or not messages[0].get("id"):
            raise ProviderError(f"WhatsApp response missing message id: {result}")
        return SendResult(str(messages[0]["id"]))
