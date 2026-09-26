import json, sqlite3, threading, uuid
from datetime import datetime, timezone
from pathlib import Path
def utcnow(): return datetime.now(timezone.utc).isoformat()
class Store:
    def __init__(self,path): self.path=Path(path); self.path.parent.mkdir(parents=True,exist_ok=True); self.lock=threading.RLock(); self._init()
    def con(self):
        c=sqlite3.connect(self.path,timeout=20,check_same_thread=False); c.row_factory=sqlite3.Row; c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA foreign_keys=ON'); return c
    def _init(self):
        with self.lock,self.con() as c:
            c.executescript("""
CREATE TABLE IF NOT EXISTS incidents(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,check_name TEXT NOT NULL,severity TEXT NOT NULL,status TEXT NOT NULL,summary TEXT NOT NULL,opened_at TEXT NOT NULL,last_seen_at TEXT NOT NULL,occurrence_count INTEGER NOT NULL,evidence_json TEXT NOT NULL,diagnosis_json TEXT,acknowledged_at TEXT,recovered_at TEXT);
CREATE INDEX IF NOT EXISTS ix_incidents_open ON incidents(status,fingerprint);
CREATE TABLE IF NOT EXISTS check_state(check_name TEXT PRIMARY KEY,last_status TEXT NOT NULL,success_streak INTEGER NOT NULL,last_checked_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS approvals(id TEXT PRIMARY KEY,incident_id TEXT NOT NULL,action_type TEXT NOT NULL,action_payload_json TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL,decided_at TEXT,decided_by TEXT,FOREIGN KEY(incident_id) REFERENCES incidents(id));
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,incident_id TEXT,event_type TEXT NOT NULL,ts TEXT NOT NULL,payload_json TEXT NOT NULL);
""")
    def event(self,event_type,payload,incident_id=None):
        with self.lock,self.con() as c: c.execute('INSERT INTO events(incident_id,event_type,ts,payload_json) VALUES(?,?,?,?)',(incident_id,event_type,utcnow(),json.dumps(payload,separators=(',',':'),default=str)))
    def open_or_update(self,**k):
        now=utcnow(); fp=k['fingerprint']; name=k['check_name']
        with self.lock,self.con() as c:
            row=c.execute("SELECT id FROM incidents WHERE fingerprint=? AND status='OPEN' ORDER BY opened_at DESC LIMIT 1",(fp,)).fetchone()
            if row:
                iid=row['id']; created=False; c.execute('UPDATE incidents SET last_seen_at=?,occurrence_count=occurrence_count+1,evidence_json=?,severity=?,summary=? WHERE id=?',(now,json.dumps(k['evidence'],default=str),k['severity'],k['summary'],iid))
            else:
                iid=f"INC-{datetime.now(timezone.utc).strftime('%Y%m%d')}-{uuid.uuid4().hex[:8].upper()}"; created=True
                c.execute('INSERT INTO incidents(id,fingerprint,check_name,severity,status,summary,opened_at,last_seen_at,occurrence_count,evidence_json) VALUES(?,?,?,?,?,?,?,?,?,?)',(iid,fp,name,k['severity'],'OPEN',k['summary'],now,now,1,json.dumps(k['evidence'],default=str)))
            c.execute("INSERT INTO check_state(check_name,last_status,success_streak,last_checked_at) VALUES(?,?,0,?) ON CONFLICT(check_name) DO UPDATE SET last_status='FAIL',success_streak=0,last_checked_at=excluded.last_checked_at",(name,'FAIL',now))
        self.event('INCIDENT_OPENED' if created else 'INCIDENT_SEEN',{'severity':k['severity'],'summary':k['summary']},iid); return iid,created
    def record_success(self,name,need):
        now=utcnow(); recovered=[]
        with self.lock,self.con() as c:
            row=c.execute('SELECT success_streak FROM check_state WHERE check_name=?',(name,)).fetchone(); streak=(int(row['success_streak']) if row else 0)+1
            c.execute("INSERT INTO check_state(check_name,last_status,success_streak,last_checked_at) VALUES(?,?,?,?) ON CONFLICT(check_name) DO UPDATE SET last_status='OK',success_streak=excluded.success_streak,last_checked_at=excluded.last_checked_at",(name,'OK',streak,now))
            if streak>=need:
                recovered=[x['id'] for x in c.execute("SELECT id FROM incidents WHERE check_name=? AND status='OPEN'",(name,)).fetchall()]
                c.execute("UPDATE incidents SET status='RECOVERED',recovered_at=? WHERE check_name=? AND status='OPEN'",(now,name))
        for iid in recovered: self.event('INCIDENT_RECOVERED',{'check_name':name},iid)
        return recovered
    def set_diagnosis(self,iid,d):
        with self.lock,self.con() as c: c.execute('UPDATE incidents SET diagnosis_json=? WHERE id=?',(json.dumps(d,default=str),iid))
        self.event('HERMES_DIAGNOSIS',d,iid)
    def create_approval(self,iid,action,payload):
        aid='APR-'+uuid.uuid4().hex[:10].upper(); now=utcnow()
        with self.lock,self.con() as c: c.execute('INSERT INTO approvals(id,incident_id,action_type,action_payload_json,status,created_at) VALUES(?,?,?,?,?,?)',(aid,iid,action,json.dumps(payload,default=str),'PENDING',now))
        self.event('APPROVAL_CREATED',{'approval_id':aid,'action_type':action},iid); return aid
    def decide_approval(self,aid,status,actor):
        status=status.upper()
        if status not in {'APPROVED','REJECTED'}: raise ValueError('bad decision')
        with self.lock,self.con() as c:
            row=c.execute('SELECT incident_id,status FROM approvals WHERE id=?',(aid,)).fetchone()
            if not row or row['status']!='PENDING': return False
            c.execute('UPDATE approvals SET status=?,decided_at=?,decided_by=? WHERE id=?',(status,utcnow(),actor,aid)); iid=row['incident_id']
        self.event('APPROVAL_'+status,{'approval_id':aid,'actor':actor,'execution':'DISABLED_OBSERVE_ONLY'},iid); return True
    def acknowledge(self,iid):
        with self.lock,self.con() as c: cur=c.execute('UPDATE incidents SET acknowledged_at=? WHERE id=?',(utcnow(),iid))
        ok=bool(cur.rowcount)
        if ok: self.event('INCIDENT_ACKNOWLEDGED',{},iid)
        return ok
    def list_incidents(self,limit=100):
        with self.lock,self.con() as c: return [dict(x) for x in c.execute('SELECT * FROM incidents ORDER BY opened_at DESC LIMIT ?',(limit,)).fetchall()]
    def list_approvals(self,limit=100):
        with self.lock,self.con() as c: return [dict(x) for x in c.execute('SELECT * FROM approvals ORDER BY created_at DESC LIMIT ?',(limit,)).fetchall()]
    def counts(self):
        with self.lock,self.con() as c:
            o={x['severity']:x['n'] for x in c.execute("SELECT severity,COUNT(*) n FROM incidents WHERE status='OPEN' GROUP BY severity")}; total=c.execute('SELECT COUNT(*) n FROM incidents').fetchone()['n']; p=c.execute("SELECT COUNT(*) n FROM approvals WHERE status='PENDING'").fetchone()['n']
        return {'open':o,'total':total,'pending_approvals':p}
