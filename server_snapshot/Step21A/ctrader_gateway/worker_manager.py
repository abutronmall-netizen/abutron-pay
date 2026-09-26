from __future__ import annotations
import json,os,queue,subprocess,sys,threading,time,uuid
from pathlib import Path
from .config import settings

class WorkerError(RuntimeError): pass

class PersistentWorker:
    def __init__(self, environment:str):
        self.environment=environment.upper()
        self.proc=None
        self.lock=threading.Lock()
        self.log_handle=None
        self.messages=queue.Queue()
        self.reader=None

    def _reader_loop(self):
        p=self.proc
        if not p or not p.stdout: return
        try:
            for line in p.stdout:
                line=line.strip()
                if not line: continue
                try: self.messages.put(json.loads(line))
                except Exception: continue
        finally:
            self.messages.put({'type':'worker_eof','ok':False,'error':'CTRADER_WORKER_PIPE_CLOSED'})

    def start(self):
        if self.proc and self.proc.poll() is None: return
        self.stop()
        while not self.messages.empty():
            try: self.messages.get_nowait()
            except queue.Empty: break
        log_dir=Path(settings.log_dir); log_dir.mkdir(parents=True,exist_ok=True)
        self.log_handle=open(log_dir/f'ctrader_{self.environment.lower()}_worker.stderr.log','a',encoding='utf-8')
        env=os.environ.copy()
        env['CTRADER_WORKER_ENV']=self.environment
        env['CTRADER_CLIENT_ID']=settings.client_id
        env['CTRADER_CLIENT_SECRET']=settings.client_secret
        self.proc=subprocess.Popen(
            [sys.executable,'-u','-m','ctrader_gateway.persistent_worker'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log_handle,
            text=True,bufsize=1,cwd=str(Path(__file__).resolve().parents[1]),env=env,
        )
        self.reader=threading.Thread(target=self._reader_loop,name=f'ctrader-{self.environment.lower()}-reader',daemon=True)
        self.reader.start()

    def stop(self):
        p=self.proc
        if p and p.poll() is None:
            try:
                if p.stdin: p.stdin.close()
                p.wait(timeout=5)
            except Exception:
                try: p.kill()
                except Exception: pass
        self.proc=None
        if self.log_handle:
            try: self.log_handle.close()
            except Exception: pass
            self.log_handle=None

    def _ensure(self):
        if not self.proc or self.proc.poll() is not None: self.start()

    def request(self, action:str, timeout:float|None=None, **kwargs):
        with self.lock:
            self._ensure()
            rid=uuid.uuid4().hex
            payload={'request_id':rid,'action':action,**kwargs}
            assert self.proc and self.proc.stdin
            try:
                self.proc.stdin.write(json.dumps(payload,separators=(',',':'))+'\n')
                self.proc.stdin.flush()
            except Exception as exc:
                self.stop(); raise WorkerError(f'CTRADER_WORKER_WRITE_FAILED:{exc}') from exc
            deadline=time.time()+(timeout if timeout is not None else settings.worker_timeout_seconds)
            while True:
                remaining=deadline-time.time()
                if remaining<=0: raise WorkerError('CTRADER_WORKER_TIMEOUT')
                try: msg=self.messages.get(timeout=remaining)
                except queue.Empty: raise WorkerError('CTRADER_WORKER_TIMEOUT')
                if msg.get('type')=='worker_eof':
                    self.stop(); raise WorkerError('CTRADER_WORKER_PIPE_CLOSED')
                # Startup, connection and heartbeat status messages are intentionally ignored here.
                if msg.get('type')=='response' and msg.get('request_id')==rid:
                    if not msg.get('ok'): raise WorkerError(f"{msg.get('error')}:{msg.get('detail','')}")
                    return msg

    def status(self):
        try: return self.request('status',timeout=3).get('status',{})
        except Exception as exc: return {'connected':False,'app_authorized':False,'error':str(exc)}

class WorkerManager:
    def __init__(self): self.workers={}
    def start(self):
        if not settings.credentials_configured: return
        if settings.enable_demo_connection:
            self.workers['DEMO']=PersistentWorker('DEMO'); self.workers['DEMO'].start()
        if settings.enable_live_connection:
            self.workers['LIVE']=PersistentWorker('LIVE'); self.workers['LIVE'].start()
    def stop(self):
        for w in list(self.workers.values()): w.stop()
        self.workers.clear()
    def _worker(self, env):
        env=env.upper()
        if env not in self.workers: raise WorkerError(f'CTRADER_{env}_CONNECTION_DISABLED')
        return self.workers[env]
    def request(self, env, action, **kwargs): return self._worker(env).request(action,**kwargs)
    def statuses(self): return {k:w.status() for k,w in self.workers.items()}

manager=WorkerManager()
