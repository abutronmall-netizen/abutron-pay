from __future__ import annotations
import argparse,time,json,sys
from .settings import Settings,load_env_file
from .db import Store
from .source import RC108Source
from .providers import TelegramProvider,WhatsAppProvider
from .engine import NotificationEngine

def context():
    load_env_file(r"C:\Abutron\Jarvis\.env",override=False)
    load_env_file(r"C:\Abutron\Jarvis\rc1_09\.env",override=True)
    s=Settings.from_env()
    store=Store(s.db_path,s.audit_path)
    source=RC108Source(s.rc1_08_url,s.jarvis_api_token)
    providers={}
    if s.telegram_enabled:
        providers["telegram"]=TelegramProvider(s.telegram_bot_token,s.telegram_chat_id)
    if s.whatsapp_enabled:
        providers["whatsapp"]=WhatsAppProvider(s.whatsapp_access_token,s.whatsapp_phone_number_id,s.whatsapp_recipient,
            s.meta_graph_version,s.whatsapp_mode,s.whatsapp_template_name,s.whatsapp_template_language)
    return s,store,source,providers

def main():
    p=argparse.ArgumentParser()
    sub=p.add_subparsers(dest="cmd",required=True)
    sub.add_parser("validate")
    t=sub.add_parser("enqueue-test"); t.add_argument("--channel",choices=["telegram","whatsapp"],required=True); t.add_argument("--wait",type=int,default=40)
    sub.add_parser("deliveries")
    a=p.parse_args()
    s,store,source,providers=context()
    if a.cmd=="validate":
        errs=s.validate(require_channels=False)
        print(json.dumps({"valid":not errs,"errors":errs,"channels":sorted(providers),"mode":"NOTIFY_ONLY","actions_enabled":False},indent=2))
        return 1 if errs else 0
    if a.cmd=="deliveries":
        print(json.dumps({"value":store.recent_deliveries(100)},indent=2,default=str)); return 0
    if a.cmd=="enqueue-test":
        if a.channel not in providers:
            print(f"CHANNEL_NOT_CONFIGURED={a.channel}"); return 2
        key=f"cert:{a.channel}:{int(time.time())}"
        event={"event_key":key,"kind":"CERTIFICATION_TEST","severity":"HIGH","title":"RC1-09 certification test",
               "body":"Notification-only transport test. No action was executed.","reference_id":key}
        store.create_event(event,[a.channel])
        eng=NotificationEngine(s,store,source,{a.channel:providers[a.channel]})
        deadline=time.time()+a.wait
        while time.time()<deadline:
            eng.dispatch_once()
            d=store.delivery_by_event_channel(key,a.channel)
            if d and d["status"]=="SENT":
                print(json.dumps({"result":"PASS","channel":a.channel,"event_key":key,"delivery":d},indent=2,default=str)); return 0
            if d and d["status"]=="DEAD":
                print(json.dumps({"result":"FAIL","channel":a.channel,"event_key":key,"delivery":d},indent=2,default=str)); return 3
            time.sleep(1)
        print(json.dumps({"result":"TIMEOUT","channel":a.channel,"event_key":key,"delivery":store.delivery_by_event_channel(key,a.channel)},indent=2,default=str))
        return 4
    return 0

if __name__=="__main__":
    raise SystemExit(main())
