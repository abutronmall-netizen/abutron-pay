import argparse,hmac,json,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlparse
from .config import load_config
from .store import Store
from .hermes import HermesDiagnostic
from .engine import IncidentEngine
class App:
    def __init__(self,cfg):
        self.cfg=cfg
        self.store=Store(cfg.raw['database_path'])
        self.store.reconcile_stale_approvals()
        self.engine=IncidentEngine(cfg,self.store,HermesDiagnostic(cfg.raw.get('hermes',{})))
    def metrics(self):
        c=self.store.counts(); L=['# TYPE jarvis_rc1_08_up gauge','jarvis_rc1_08_up 1',f'jarvis_rc1_08_cycles_total {self.engine.cycles}',f'jarvis_rc1_08_hermes_failures_total {self.engine.hermes_failures}',f"jarvis_rc1_08_pending_approvals {c['pending_approvals']}",f"jarvis_rc1_08_incidents_total {c['total']}"]
        for s in ('INFO','LOW','MEDIUM','HIGH','CRITICAL'): L.append(f'jarvis_rc1_08_open_incidents{{severity="{s}"}} {c["open"].get(s,0)}')
        L.append(f'jarvis_rc1_08_last_cycle_unixtime {self.engine.last_cycle}'); L.append(f'jarvis_rc1_08_suppressed_failures_total {self.engine.suppressed_failures}'); L.append(f'jarvis_rc1_08_startup_grace_active {1 if self.engine.startup_grace_active() else 0}'); return '\n'.join(L)+'\n'
def handler(app):
 class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def auth(self):
        tok=app.cfg.token; got=self.headers.get('Authorization',''); return bool(tok) and got.startswith('Bearer ') and hmac.compare_digest(got[7:],tok)
    def js(self,code,obj):
        b=json.dumps(obj,default=str).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p=urlparse(self.path).path
        if p=='/health': return self.js(200,{'status':'ok','mode':app.cfg.mode,'cycles':app.engine.cycles,'last_cycle':app.engine.last_cycle,'startup_grace_active':app.engine.startup_grace_active(),'startup_grace_remaining_seconds':round(app.engine.startup_grace_remaining(),3),'suppressed_failures_total':app.engine.suppressed_failures})
        if p=='/metrics':
            b=app.metrics().encode(); self.send_response(200); self.send_header('Content-Type','text/plain; version=0.0.4'); self.send_header('Content-Length',str(len(b))); self.end_headers(); return self.wfile.write(b)
        if not self.auth(): return self.js(401,{'error':'unauthorized'})
        if p=='/incidents': return self.js(200,app.store.list_incidents())
        if p=='/approvals': return self.js(200,app.store.list_approvals())
        return self.js(404,{'error':'not_found'})
    def do_POST(self):
        if not self.auth(): return self.js(401,{'error':'unauthorized'})
        p=urlparse(self.path).path
        if p=='/collect': return self.js(200,app.engine.cycle())
        z=[x for x in p.split('/') if x]
        if len(z)==3 and z[0]=='incidents' and z[2]=='ack':
            ok=app.store.acknowledge(z[1]); return self.js(200 if ok else 404,{'ok':ok})
        if len(z)==3 and z[0]=='approvals' and z[2] in {'approve','reject'}:
            d='APPROVED' if z[2]=='approve' else 'REJECTED'; ok=app.store.decide_approval(z[1],d,'api-user'); return self.js(200 if ok else 409,{'ok':ok,'decision':d,'execution':'DISABLED_OBSERVE_ONLY'})
        return self.js(404,{'error':'not_found'})
 return H
def main():
    a=argparse.ArgumentParser(); a.add_argument('--config',required=True); x=a.parse_args(); cfg=load_config(x.config); app=App(cfg); threading.Thread(target=app.engine.loop,daemon=True).start(); h=cfg.raw.get('http',{}); srv=ThreadingHTTPServer((h.get('host','127.0.0.1'),int(h.get('port',8788))),handler(app))
    try: srv.serve_forever()
    finally: app.engine.stop_event.set(); srv.server_close()
if __name__=='__main__': main()
