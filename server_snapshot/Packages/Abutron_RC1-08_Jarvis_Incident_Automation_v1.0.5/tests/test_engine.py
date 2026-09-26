import tempfile,unittest,sys,time,sqlite3
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from rc1_08.config import Config
from rc1_08.store import Store
from rc1_08.engine import IncidentEngine
from rc1_08.collectors import CheckResult
class FakeHermes:
 def diagnose(self,inc): return {'status':'OK','recommended_action':{'type':'RUN_HEALTH_CHECK','params':{}},'requires_human':True}
class T(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); p=Path(self.tmp.name); raw={'mode':'OBSERVE_ONLY','interval_seconds':30,'recovery_confirmations':2,'database_path':str(p/'x.db'),'audit_log_path':str(p/'a.jsonl'),'checks':[],'hermes':{'minimum_severity':'HIGH'},'approval_action_allowlist':['RUN_HEALTH_CHECK']}; self.cfg=Config(raw,p/'c'); self.s=Store(raw['database_path']); self.e=IncidentEngine(self.cfg,self.s,FakeHermes())
 def tearDown(self): self.tmp.cleanup()
 def test_dedupe_recovery(self):
  r=CheckResult('mt5',False,'CRITICAL','mt5 down',{}); i,c=self.s.open_or_update(fingerprint=self.e.fingerprint(r),check_name=r.name,severity=r.severity,summary=r.summary,evidence={}); j,d=self.s.open_or_update(fingerprint=self.e.fingerprint(r),check_name=r.name,severity=r.severity,summary=r.summary,evidence={}); self.assertTrue(c); self.assertFalse(d); self.assertEqual(i,j); self.assertEqual(self.s.list_incidents()[0]['occurrence_count'],2); self.assertEqual(self.s.record_success('mt5',2),[]); self.assertEqual(self.s.record_success('mt5',2),[i]); self.assertEqual(self.s.list_incidents()[0]['status'],'RECOVERED')
 def test_same_check_different_errors_share_fingerprint(self):
  a=CheckResult('jarvis_api',False,'CRITICAL','connection refused',{}); b=CheckResult('jarvis_api',False,'CRITICAL','connection reset',{}); self.assertEqual(self.e.fingerprint(a),self.e.fingerprint(b))
 def test_store_connection_closes_after_context(self):
  with self.s.con() as c:
   c.execute('SELECT 1').fetchone()
  with self.assertRaises(sqlite3.ProgrammingError):
   c.execute('SELECT 1')
 def test_approval_no_execution(self):
  r=CheckResult('x',False,'HIGH','fail',{}); i,_=self.s.open_or_update(fingerprint=self.e.fingerprint(r),check_name='x',severity='HIGH',summary='fail',evidence={}); self.e._diagnose(i,r); a=self.s.list_approvals()[0]; self.assertEqual(a['status'],'PENDING'); self.assertTrue(self.s.decide_approval(a['id'],'APPROVED','tester')); self.assertEqual(self.s.list_approvals()[0]['status'],'APPROVED')
 def test_startup_reconcile_cancels_legacy_pending_approval(self):
  r=CheckResult('legacy',False,'HIGH','legacy down',{})
  i,_=self.s.open_or_update(fingerprint=self.e.fingerprint(r),check_name='legacy',severity='HIGH',summary='legacy down',evidence={})
  self.e._diagnose(i,r)
  a=self.s.list_approvals()[0]
  self.assertEqual(a['status'],'PENDING')
  with self.s.lock,self.s.con() as c:
   c.execute("UPDATE incidents SET status='RECOVERED',recovered_at=? WHERE id=?",('2026-09-26T00:00:00+00:00',i))
  cancelled=self.s.reconcile_stale_approvals()
  self.assertEqual(cancelled,[a['id']])
  a2=self.s.list_approvals()[0]
  self.assertEqual(a2['status'],'CANCELLED')
  self.assertEqual(a2['decided_by'],'system-recovery-reconcile')
 def test_recovery_cancels_pending_approval(self):
  r=CheckResult('svc',False,'HIGH','svc down',{}); i,_=self.s.open_or_update(fingerprint=self.e.fingerprint(r),check_name='svc',severity='HIGH',summary='svc down',evidence={}); self.e._diagnose(i,r); a=self.s.list_approvals()[0]; self.assertEqual(a['status'],'PENDING'); self.assertEqual(self.s.record_success('svc',2),[]); self.assertEqual(self.s.record_success('svc',2),[i]); a2=self.s.list_approvals()[0]; self.assertEqual(a2['status'],'CANCELLED'); self.assertEqual(a2['decided_by'],'system-recovery')

class BootHardeningT(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); p=Path(self.tmp.name)
  raw={'mode':'OBSERVE_ONLY','interval_seconds':30,'recovery_confirmations':2,'failure_confirmations':2,'startup_grace_seconds':0,'database_path':str(p/'x.db'),'audit_log_path':str(p/'a.jsonl'),'checks':[{'type':'url','name':'api','url':'http://127.0.0.1:1/health','severity':'CRITICAL','failure_confirmations':2}],'hermes':{'minimum_severity':'HIGH'},'approval_action_allowlist':['RUN_HEALTH_CHECK']}
  self.cfg=Config(raw,p/'c'); self.s=Store(raw['database_path']); self.e=IncidentEngine(self.cfg,self.s,FakeHermes())
 def tearDown(self): self.tmp.cleanup()
 def _run_with(self,results):
  import rc1_08.engine as eng
  old=eng.run_check
  seq=iter(results)
  eng.run_check=lambda spec: next(seq)
  try:
   for _ in results: self.e.cycle()
  finally:
   eng.run_check=old
 def test_single_transient_failure_does_not_open(self):
  self._run_with([CheckResult('api',False,'CRITICAL','refused',{})])
  self.assertEqual(self.s.list_incidents(),[])
  self.assertEqual(self.e.suppressed_failures,1)
 def test_two_consecutive_failures_open(self):
  self._run_with([CheckResult('api',False,'CRITICAL','refused',{}),CheckResult('api',False,'CRITICAL','refused',{})])
  inc=self.s.list_incidents(); self.assertEqual(len(inc),1); self.assertEqual(inc[0]['status'],'OPEN')
 def test_success_resets_failure_streak(self):
  self._run_with([CheckResult('api',False,'CRITICAL','refused',{}),CheckResult('api',True,'CRITICAL','ok',{}),CheckResult('api',False,'CRITICAL','refused',{})])
  self.assertEqual(self.s.list_incidents(),[])
 def test_startup_grace_suppresses_failure(self):
  self.e.config.raw['startup_grace_seconds']=300
  self.e.started_at=time.time()
  self._run_with([CheckResult('api',False,'CRITICAL','refused',{}),CheckResult('api',False,'CRITICAL','refused',{})])
  self.assertEqual(self.s.list_incidents(),[])

if __name__=='__main__': unittest.main()
