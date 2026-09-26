import hashlib, threading, time
from .collectors import run_check
from .config import SEVERITY_RANK
from .audit import write_audit

class IncidentEngine:
    def __init__(self,config,store,hermes):
        self.config=config
        self.store=store
        self.hermes=hermes
        self.stop_event=threading.Event()
        self.last_cycle=0.0
        self.cycles=0
        self.hermes_failures=0
        self.started_at=time.time()
        self.failure_streaks={}
        self.suppressed_failures=0

    def fingerprint(self,r):
        return hashlib.sha256(f'check:{r.name}'.encode()).hexdigest()[:24]

    def startup_grace_remaining(self):
        return max(0.0, self.config.startup_grace_seconds - (time.time() - self.started_at))

    def startup_grace_active(self):
        return self.startup_grace_remaining() > 0

    def _needed_failures(self,spec):
        try:
            return max(1,int(spec.get('failure_confirmations',self.config.failure_confirmations)))
        except Exception:
            return self.config.failure_confirmations

    def cycle(self):
        opened=[]
        recovered=[]
        grace=self.startup_grace_active()
        for spec in self.config.raw.get('checks',[]):
            r=run_check(spec)
            if r.ok:
                self.failure_streaks[r.name]=0
                recovered+=self.store.record_success(r.name,self.config.recovery_confirmations)
                continue

            # Windows/service startup commonly produces one-off connection refused/reset
            # errors while dependencies bind their sockets. During the startup grace
            # period we record evidence but do not create incidents. Failure streaks
            # are intentionally not carried out of the grace period.
            if grace:
                self.failure_streaks[r.name]=0
                self.suppressed_failures+=1
                write_audit(self.config.raw['audit_log_path'],'STARTUP_FAILURE_SUPPRESSED',{
                    'check_name':r.name,'severity':r.severity,'summary':r.summary,
                    'grace_remaining_seconds':round(self.startup_grace_remaining(),3),
                    'evidence':r.evidence
                })
                continue

            needed=self._needed_failures(spec)
            streak=self.failure_streaks.get(r.name,0)+1
            self.failure_streaks[r.name]=streak
            if streak < needed:
                self.suppressed_failures+=1
                write_audit(self.config.raw['audit_log_path'],'CHECK_FAILURE_PENDING_CONFIRMATION',{
                    'check_name':r.name,'severity':r.severity,'summary':r.summary,
                    'failure_streak':streak,'failure_confirmations':needed,
                    'evidence':r.evidence
                })
                continue

            iid,created=self.store.open_or_update(
                fingerprint=self.fingerprint(r),check_name=r.name,severity=r.severity,
                summary=r.summary,evidence=r.evidence)
            if created:
                opened.append(iid)
                self._diagnose(iid,r)

        self.last_cycle=time.time()
        self.cycles+=1
        write_audit(self.config.raw['audit_log_path'],'CYCLE',{
            'opened':opened,'recovered':recovered,
            'checks':len(self.config.raw.get('checks',[])),
            'startup_grace_active':grace
        })
        return {'opened':opened,'recovered':recovered}

    def _diagnose(self,iid,r):
        h=self.config.raw.get('hermes',{})
        minimum=str(h.get('minimum_severity','HIGH')).upper()
        if SEVERITY_RANK.get(r.severity,0)<SEVERITY_RANK.get(minimum,40):
            return
        try:
            d=self.hermes.diagnose({'id':iid,'check_name':r.name,'severity':r.severity,'summary':r.summary,'evidence':r.evidence})
            self.store.set_diagnosis(iid,d)
            action=((d or {}).get('recommended_action') or {}).get('type','NONE')
            if action and action!='NONE':
                if action in set(self.config.raw.get('approval_action_allowlist',[])):
                    self.store.create_approval(iid,action,(d.get('recommended_action') or {}).get('params',{}))
                else:
                    self.store.event('ACTION_REJECTED_BY_ALLOWLIST',{'action_type':action},iid)
        except Exception as e:
            self.hermes_failures+=1
            self.store.event('HERMES_DIAGNOSIS_FAILED',{'error_type':type(e).__name__,'error':str(e)[:1000]},iid)

    def loop(self):
        while not self.stop_event.is_set():
            start=time.time()
            try:
                self.cycle()
            except Exception as e:
                write_audit(self.config.raw['audit_log_path'],'ENGINE_ERROR',{'error_type':type(e).__name__,'error':str(e)[:1000]})
            self.stop_event.wait(max(1,self.config.interval_seconds-(time.time()-start)))
