from __future__ import annotations
import json,time,threading,urllib.parse
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from .settings import Settings,load_env_file
from .db import Store
from .source import RC108Source
from .providers import TelegramProvider,WhatsAppProvider
from .engine import NotificationEngine
from .webhooks import valid_meta_signature,extract_whatsapp_statuses

def build(settings:Settings):
    store=Store(settings.db_path,settings.audit_path)
    source=RC108Source(settings.rc1_08_url,settings.jarvis_api_token)
    providers={}
    if settings.telegram_enabled:
        providers["telegram"]=TelegramProvider(settings.telegram_bot_token,settings.telegram_chat_id)
    if settings.whatsapp_enabled:
        providers["whatsapp"]=WhatsAppProvider(
            settings.whatsapp_access_token,settings.whatsapp_phone_number_id,
            settings.whatsapp_recipient,settings.meta_graph_version,
            settings.whatsapp_mode,settings.whatsapp_template_name,settings.whatsapp_template_language
        )
    engine=NotificationEngine(settings,store,source,providers)
    return store,source,engine

class State:
    started=time.time()

def run():
    load_env_file(r"C:\Abutron\Jarvis\.env",override=False)
    load_env_file(r"C:\Abutron\Jarvis\rc1_09\.env",override=True)
    s=Settings.from_env()
    errors=s.validate(require_channels=False)
    fatal=[e for e in errors if not e.startswith("At least one")]
    if fatal:
        raise SystemExit("CONFIG_ERROR: "+"; ".join(fatal))
    store,source,engine=build(s)
    stop=threading.Event()

    def worker():
        while not stop.is_set():
            engine.cycle()
            stop.wait(s.poll_seconds)
    threading.Thread(target=worker,name="rc1-09-worker",daemon=True).start()

    class H(BaseHTTPRequestHandler):
        server_version="AbutronRC109/1.0.0"
        def log_message(self,*args): return
        def _json(self,code,obj):
            raw=json.dumps(obj,separators=(",",":"),default=str).encode()
            self.send_response(code)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        def _auth(self):
            h=self.headers.get("Authorization","")
            return bool(s.api_token) and h==f"Bearer {s.api_token}"
        def do_GET(self):
            u=urllib.parse.urlparse(self.path)
            if u.path=="/health":
                try:
                    rh=source.health()
                    rc_ok=rh.get("status")=="ok" and rh.get("mode")=="OBSERVE_ONLY"
                except Exception:
                    rc_ok=False
                configured={"telegram":"telegram" in engine.providers,"whatsapp":"whatsapp" in engine.providers}
                self._json(200,{
                    "status":"ok" if rc_ok else "degraded",
                    "mode":"NOTIFY_ONLY",
                    "actions_enabled":False,
                    "rc1_08_ok":rc_ok,
                    "cycles":engine.cycles,
                    "last_cycle":engine.last_cycle,
                    "poll_failures":engine.poll_failures,
                    "delivery_failures":engine.delivery_failures,
                    "channels":configured,
                    "uptime_seconds":round(time.time()-State.started,1),
                }); return
            if u.path=="/metrics":
                c=store.counts()
                text=(
                    "# TYPE jarvis_rc1_09_up gauge\njarvis_rc1_09_up 1\n"
                    f"jarvis_rc1_09_cycles_total {engine.cycles}\n"
                    f"jarvis_rc1_09_poll_failures_total {engine.poll_failures}\n"
                    f"jarvis_rc1_09_delivery_failures_total {engine.delivery_failures}\n"
                    f"jarvis_rc1_09_events_total {c['events']}\n"
                    f"jarvis_rc1_09_deliveries_queued {c['queued']}\n"
                    f"jarvis_rc1_09_deliveries_retry {c['retry']}\n"
                    f"jarvis_rc1_09_deliveries_sent {c['sent']}\n"
                    f"jarvis_rc1_09_deliveries_dead {c['dead']}\n"
                ).encode()
                self.send_response(200); self.send_header("Content-Type","text/plain; version=0.0.4")
                self.send_header("Content-Length",str(len(text))); self.end_headers(); self.wfile.write(text); return
            if u.path=="/deliveries":
                if not self._auth(): self._json(401,{"error":"unauthorized"}); return
                self._json(200,{"value":store.recent_deliveries(100)}); return
            if u.path=="/whatsapp/webhook":
                qs=urllib.parse.parse_qs(u.query)
                if qs.get("hub.mode",[""])[0]=="subscribe" and qs.get("hub.verify_token",[""])[0]==s.whatsapp_verify_token:
                    body=qs.get("hub.challenge",[""])[0].encode()
                    self.send_response(200); self.send_header("Content-Type","text/plain")
                    self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body); return
                self._json(403,{"error":"verification_failed"}); return
            self._json(404,{"error":"not_found"})
        def do_POST(self):
            u=urllib.parse.urlparse(self.path)
            if u.path!="/whatsapp/webhook":
                self._json(404,{"error":"not_found"}); return
            n=int(self.headers.get("Content-Length","0") or "0")
            raw=self.rfile.read(n)
            sig=self.headers.get("X-Hub-Signature-256","")
            if not valid_meta_signature(raw,sig,s.meta_app_secret):
                self._json(401,{"error":"bad_signature"}); return
            try: payload=json.loads(raw.decode("utf-8"))
            except Exception:
                self._json(400,{"error":"bad_json"}); return
            # Notification-only: ignore inbound messages; only consume delivery statuses.
            for st in extract_whatsapp_statuses(payload):
                store.update_provider_status(st["id"],st["status"],st.get("error"))
            self._json(200,{"ok":True})
    srv=ThreadingHTTPServer((s.bind,s.port),H)
    try:
        srv.serve_forever()
    finally:
        stop.set()
        srv.server_close()

if __name__=="__main__":
    run()
