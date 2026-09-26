from __future__ import annotations
from contextlib import contextmanager
from pathlib import Path
import sqlite3, json, time, datetime as dt

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS entity_state(
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  status TEXT NOT NULL,
  updated_at REAL NOT NULL,
  PRIMARY KEY(entity_type, entity_id)
);
CREATE TABLE IF NOT EXISTS events(
  event_key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  severity TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  reference_id TEXT NOT NULL,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS deliveries(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_key TEXT NOT NULL,
  channel TEXT NOT NULL,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at REAL NOT NULL,
  provider_message_id TEXT,
  provider_status TEXT,
  last_error TEXT,
  created_at REAL NOT NULL,
  sent_at REAL,
  updated_at REAL NOT NULL,
  UNIQUE(event_key, channel)
);
CREATE TABLE IF NOT EXISTS audit(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  action TEXT NOT NULL,
  detail_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deliveries_due
ON deliveries(status,next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_deliveries_provider_id
ON deliveries(provider_message_id);
"""

class Store:
    def __init__(self, db_path: str, audit_path: str|None=None):
        self.db_path = str(db_path)
        self.audit_path = str(audit_path) if audit_path else ""
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        if self.audit_path:
            Path(self.audit_path).parent.mkdir(parents=True, exist_ok=True)
        with self.con() as c:
            c.executescript(SCHEMA)

    @contextmanager
    def con(self):
        c = sqlite3.connect(self.db_path, timeout=30)
        c.row_factory = sqlite3.Row
        try:
            yield c
            c.commit()
        except Exception:
            c.rollback()
            raise
        finally:
            c.close()

    def audit(self, action: str, detail: dict) -> None:
        now=time.time()
        payload=json.dumps(detail,sort_keys=True,separators=(",",":"),default=str)
        with self.con() as c:
            c.execute("INSERT INTO audit(ts,action,detail_json) VALUES(?,?,?)",(now,action,payload))
        if self.audit_path:
            rec={"ts":dt.datetime.fromtimestamp(now,dt.timezone.utc).isoformat(),"action":action,"detail":detail}
            with open(self.audit_path,"a",encoding="utf-8") as f:
                f.write(json.dumps(rec,sort_keys=True,default=str)+"\n")

    def get_state(self, entity_type: str, entity_id: str):
        with self.con() as c:
            r=c.execute("SELECT status FROM entity_state WHERE entity_type=? AND entity_id=?",(entity_type,entity_id)).fetchone()
        return r["status"] if r else None

    def set_state(self, entity_type: str, entity_id: str, status: str) -> None:
        with self.con() as c:
            c.execute("""INSERT INTO entity_state(entity_type,entity_id,status,updated_at)
                         VALUES(?,?,?,?)
                         ON CONFLICT(entity_type,entity_id)
                         DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at""",
                      (entity_type,entity_id,status,time.time()))

    def create_event(self, event: dict, channels: list[str]) -> bool:
        now=time.time()
        inserted=False
        with self.con() as c:
            cur=c.execute("""INSERT OR IGNORE INTO events(event_key,kind,severity,title,body,reference_id,created_at)
                             VALUES(?,?,?,?,?,?,?)""",
                          (event["event_key"],event["kind"],event["severity"],event["title"],event["body"],event["reference_id"],now))
            inserted = cur.rowcount == 1
            if inserted:
                for ch in channels:
                    c.execute("""INSERT OR IGNORE INTO deliveries(event_key,channel,status,attempts,next_attempt_at,created_at,updated_at)
                                 VALUES(?,?, 'QUEUED',0,?,?,?)""",(event["event_key"],ch,now,now,now))
        if inserted:
            self.audit("EVENT_CREATED",{"event_key":event["event_key"],"channels":channels,"kind":event["kind"]})
        return inserted

    def due_deliveries(self, limit: int=25) -> list[dict]:
        with self.con() as c:
            rows=c.execute("""SELECT d.*,e.kind,e.severity,e.title,e.body,e.reference_id
                              FROM deliveries d JOIN events e ON e.event_key=d.event_key
                              WHERE d.status IN ('QUEUED','RETRY') AND d.next_attempt_at<=?
                              ORDER BY d.next_attempt_at,d.id LIMIT ?""",(time.time(),limit)).fetchall()
        return [dict(r) for r in rows]

    def mark_sent(self, delivery_id: int, provider_message_id: str|None) -> None:
        now=time.time()
        with self.con() as c:
            c.execute("""UPDATE deliveries SET status='SENT',attempts=attempts+1,
                         provider_message_id=?,provider_status='accepted',last_error=NULL,
                         sent_at=?,updated_at=? WHERE id=?""",(provider_message_id,now,now,delivery_id))
        self.audit("DELIVERY_SENT",{"delivery_id":delivery_id,"provider_message_id":provider_message_id})

    def mark_retry(self, delivery_id: int, error: str, delay_seconds: int, max_attempts: int) -> None:
        now=time.time()
        with self.con() as c:
            row=c.execute("SELECT attempts FROM deliveries WHERE id=?",(delivery_id,)).fetchone()
            attempts=(int(row["attempts"]) if row else 0)+1
            status="DEAD" if attempts>=max_attempts else "RETRY"
            c.execute("""UPDATE deliveries SET status=?,attempts=?,next_attempt_at=?,
                         last_error=?,updated_at=? WHERE id=?""",
                      (status,attempts,now+delay_seconds,error[:2000],now,delivery_id))
        self.audit("DELIVERY_"+status,{"delivery_id":delivery_id,"attempts":attempts,"error":error[:500]})

    def update_provider_status(self, provider_message_id: str, provider_status: str, error: str|None=None) -> bool:
        now=time.time()
        with self.con() as c:
            cur=c.execute("""UPDATE deliveries SET provider_status=?,last_error=COALESCE(?,last_error),updated_at=?
                             WHERE provider_message_id=?""",
                          (provider_status,error,now,provider_message_id))
            changed=cur.rowcount>0
        if changed:
            self.audit("PROVIDER_STATUS",{"provider_message_id":provider_message_id,"status":provider_status,"error":error})
        return changed

    def delivery_by_event_channel(self,event_key:str,channel:str):
        with self.con() as c:
            r=c.execute("SELECT * FROM deliveries WHERE event_key=? AND channel=?",(event_key,channel)).fetchone()
        return dict(r) if r else None

    def counts(self) -> dict:
        out={}
        with self.con() as c:
            out["events"]=c.execute("SELECT COUNT(*) n FROM events").fetchone()["n"]
            for s in ("QUEUED","RETRY","SENT","DEAD"):
                out[s.lower()]=c.execute("SELECT COUNT(*) n FROM deliveries WHERE status=?",(s,)).fetchone()["n"]
        return out

    def recent_deliveries(self, limit:int=100)->list[dict]:
        with self.con() as c:
            rows=c.execute("""SELECT d.*,e.kind,e.severity,e.title,e.reference_id
                              FROM deliveries d JOIN events e ON e.event_key=d.event_key
                              ORDER BY d.id DESC LIMIT ?""",(limit,)).fetchall()
        return [dict(r) for r in rows]
