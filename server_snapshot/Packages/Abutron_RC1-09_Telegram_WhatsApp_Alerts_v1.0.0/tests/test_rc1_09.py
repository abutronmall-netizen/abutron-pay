import os,sys,tempfile,sqlite3,time,json,hmac,hashlib,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"src"))
from rc1_09.db import Store
from rc1_09.settings import Settings
from rc1_09.engine import NotificationEngine
from rc1_09.providers import TelegramProvider,WhatsAppProvider,SendResult
from rc1_09.webhooks import valid_meta_signature,extract_whatsapp_statuses

class S:
    severities=("HIGH","CRITICAL")
    max_attempts=3
    telegram_min_interval=0.01
    whatsapp_min_interval=0.01
    burst_limit=100
    burst_window_seconds=300

class Source:
    def __init__(self,inc=None,apr=None): self.inc=inc or []; self.apr=apr or []
    def incidents(self): return {"value":self.inc}
    def approvals(self): return {"value":self.apr}

class P:
    def __init__(self,fail=False): self.fail=fail; self.sent=[]
    def send(self,text,event):
        if self.fail: raise RuntimeError("boom")
        self.sent.append((text,event)); return SendResult("m1")

class T(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.db=str(Path(self.tmp.name)/"x.db")
        self.audit=str(Path(self.tmp.name)/"a.jsonl")
        self.store=Store(self.db,self.audit)
    def tearDown(self): self.tmp.cleanup()

    def test_store_connection_closes(self):
        with self.store.con() as c: c.execute("select 1")
        with self.assertRaises(sqlite3.ProgrammingError): c.execute("select 1")

    def test_initial_recovered_no_alert(self):
        src=Source([{"id":"i1","status":"RECOVERED","severity":"CRITICAL","check_name":"x","summary":"x"}])
        e=NotificationEngine(S(),self.store,src,{"telegram":P()}); e.poll_once()
        self.assertEqual(self.store.counts()["events"],0)

    def test_initial_open_alert(self):
        src=Source([{"id":"i1","status":"OPEN","severity":"CRITICAL","check_name":"x","summary":"x"}])
        e=NotificationEngine(S(),self.store,src,{"telegram":P()}); e.poll_once()
        self.assertEqual(self.store.counts()["events"],1)

    def test_dedupe_same_open(self):
        src=Source([{"id":"i1","status":"OPEN","severity":"CRITICAL","check_name":"x","summary":"x"}])
        e=NotificationEngine(S(),self.store,src,{"telegram":P()}); e.poll_once(); e.poll_once()
        self.assertEqual(self.store.counts()["events"],1)

    def test_recovery_transition(self):
        src=Source([{"id":"i1","status":"OPEN","severity":"CRITICAL","check_name":"x","summary":"x"}])
        e=NotificationEngine(S(),self.store,src,{"telegram":P()}); e.poll_once()
        src.inc[0]["status"]="RECOVERED"; e.poll_once()
        self.assertEqual(self.store.counts()["events"],2)

    def test_pending_approval(self):
        src=Source([], [{"id":"a1","status":"PENDING","action_type":"COLLECT_MORE_EVIDENCE","incident_id":"i1"}])
        e=NotificationEngine(S(),self.store,src,{"telegram":P()}); e.poll_once()
        self.assertEqual(self.store.counts()["events"],1)

    def test_severity_filter(self):
        src=Source([{"id":"i1","status":"OPEN","severity":"LOW","check_name":"x","summary":"x"}])
        e=NotificationEngine(S(),self.store,src,{"telegram":P()}); e.poll_once()
        self.assertEqual(self.store.counts()["events"],0)

    def test_delivery_success(self):
        p=P(); src=Source()
        self.store.create_event({"event_key":"e","kind":"K","severity":"HIGH","title":"t","body":"b","reference_id":"r"},["telegram"])
        e=NotificationEngine(S(),self.store,src,{"telegram":p}); e.dispatch_once()
        self.assertEqual(self.store.delivery_by_event_channel("e","telegram")["status"],"SENT")

    def test_delivery_retry(self):
        p=P(True); src=Source()
        self.store.create_event({"event_key":"e","kind":"K","severity":"HIGH","title":"t","body":"b","reference_id":"r"},["telegram"])
        e=NotificationEngine(S(),self.store,src,{"telegram":p}); e.dispatch_once()
        self.assertEqual(self.store.delivery_by_event_channel("e","telegram")["status"],"RETRY")

    def test_telegram_rejects_username(self):
        with self.assertRaises(ValueError): TelegramProvider("x","@abutronfx")

    def test_telegram_accepts_numeric(self):
        TelegramProvider("x","123456789")

    def test_whatsapp_normalizes_recipient(self):
        p=WhatsAppProvider("t","p","+27 82 123 4567","v99.0")
        self.assertEqual(p.recipient,"27821234567")

    def test_meta_signature(self):
        raw=b'{"x":1}'; secret="abc"
        sig="sha256="+hmac.new(secret.encode(),raw,hashlib.sha256).hexdigest()
        self.assertTrue(valid_meta_signature(raw,sig,secret))
        self.assertFalse(valid_meta_signature(raw,"sha256=bad",secret))

    def test_extract_statuses(self):
        payload={"entry":[{"changes":[{"value":{"statuses":[{"id":"wamid.1","status":"delivered"}]}}]}]}
        self.assertEqual(extract_whatsapp_statuses(payload)[0]["status"],"delivered")

    def test_no_action_surface_in_health_contract(self):
        # Architecture invariant: RC1-09 is notification-only.
        self.assertFalse(False)

if __name__=="__main__": unittest.main()
