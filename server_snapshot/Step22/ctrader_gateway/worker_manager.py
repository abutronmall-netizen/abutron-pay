from __future__ import annotations
import json,os,queue,subprocess,sys,threading,time,uuid
from pathlib import Path
from .config import settings

class WorkerError(RuntimeError): pass

READ_ONLY_ACTIONS={
    'status','accounts','trader','reconcile','symbols','assets','pnl','symbol-details',
    'subscribe-spots','spot-snapshot','deal-list','order-list'
}
MUTATING_ACTIONS={'market-order','close-position','amend-position'}
RESTARTABLE_ERRORS=('CTRADER_WORKER_PIPE_CLOSED','CTRADER_WORKER_WRITE_FAILED','OPEN_API_NOT_READY')

class PersistentWorker:
    def __init__(self, environment:str):
        self.environment=environment.upper(); self.proc=None; self.lock=threading.Lock(); self.log_handle=None
        self.messages=queue.Queue(); self.reader=None; self.restart_count=0; self.last_restart_at=None

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
        env=os.environ.copy(); env['CTRADER_WORKER_ENV']=self.environment; env['CTRADER_CLIENT_ID']=settings.client_id; env['CTRADER_CLIENT_SECRET']=settings.client_secret
        self.proc=subprocess.Popen([sys.executable,'-u','-m','ctrader_gateway.persistent_worker'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=self.log_handle,text=True,bufsize=1,cwd=str(Path(__file__).resolve().parents[1]),env=env)
        self.reader=threading.Thread(target=self._reader_loop,name=f'ctrader-{self.environment.lower()}-reader',daemon=True); self.reader.start()
        self.restart_count+=1; self.last_restart_at=int(time.time())

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

    def restart(self): self.stop(); self.start()
    def _ensure(self):
        if not self.proc or self.proc.poll() is not None: self.start()

    def request(self, action:str, timeout:float|None=None, **kwargs):
        with self.lock:
            self._ensure(); rid=uuid.uuid4().hex; payload={'request_id':rid,'action':action,**kwargs}
            assert self.proc and self.proc.stdin
            try:
                self.proc.stdin.write(json.dumps(payload,separators=(',',':'))+'\n'); self.proc.stdin.flush()
            except Exception as exc:
                self.stop(); raise WorkerError(f'CTRADER_WORKER_WRITE_FAILED:{exc}') from exc
            deadline=time.time()+(timeout if timeout is not None else settings.worker_timeout_seconds)
            while True:
                remaining=deadline-time.time()
                if remaining<=0: raise WorkerError('CTRADER_WORKER_TIMEOUT')
                try: msg=self.messages.get(timeout=remaining)
                except queue.Empty: raise WorkerError('CTRADER_WORKER_TIMEOUT')
                if msg.get('type')=='worker_eof': self.stop(); raise WorkerError('CTRADER_WORKER_PIPE_CLOSED')
                if msg.get('type')=='response' and msg.get('request_id')==rid:
                    if not msg.get('ok'): raise WorkerError(f"{msg.get('error')}:{msg.get('detail','')}")
                    return msg

    def status(self):
        try:
            out=self.request('status',timeout=3).get('status',{}); out['restart_count']=self.restart_count; out['last_restart_at']=self.last_restart_at; return out
        except Exception as exc:
            return {'connected':False,'app_authorized':False,'error':str(exc),'restart_count':self.restart_count,'last_restart_at':self.last_restart_at}

class WorkerManager:
    def __init__(self): self.workers={}
    def start(self):
        if not settings.credentials_configured: return
        if settings.enable_demo_connection: self.workers['DEMO']=PersistentWorker('DEMO'); self.workers['DEMO'].start()
        if settings.enable_live_connection: self.workers['LIVE']=PersistentWorker('LIVE'); self.workers['LIVE'].start()
    def stop(self):
        for w in list(self.workers.values()): w.stop()
        self.workers.clear()
    def _worker(self, env):
        env=env.upper()
        if env not in self.workers: raise WorkerError(f'CTRADER_{env}_CONNECTION_DISABLED')
        return self.workers[env]
    def restart(self, env): self._worker(env).restart()
    def request(self, env, action, **kwargs):
        w=self._worker(env)
        try: return w.request(action,**kwargs)
        except WorkerError as exc:
            # Step 21D: a broker mutation may have reached cTrader before transport loss. NEVER replay it.
            # One bounded restart/retry is permitted only for read-only requests.
            if not settings.step21d_read_retry_enabled or action not in READ_ONLY_ACTIONS: raise
            if not any(marker in str(exc) for marker in RESTARTABLE_ERRORS): raise
            w.restart(); time.sleep(0.35)
            return w.request(action,**kwargs)
    def statuses(self): return {k:w.status() for k,w in self.workers.items()}

manager=WorkerManager()
