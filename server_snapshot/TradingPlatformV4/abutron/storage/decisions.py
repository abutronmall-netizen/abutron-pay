import json,sqlite3,threading,time
from pathlib import Path
from abutron.config import settings

class DecisionStore:
    def __init__(self,path=None):
        self.path=path or settings.decision_db
        Path(self.path).parent.mkdir(parents=True,exist_ok=True)
        self.lock=threading.Lock()
        with self._db() as db:
            db.execute("CREATE TABLE IF NOT EXISTS decisions(id INTEGER PRIMARY KEY AUTOINCREMENT,created_ts INTEGER NOT NULL,symbol TEXT NOT NULL,mode TEXT NOT NULL,direction TEXT NOT NULL,confidence REAL NOT NULL,approved INTEGER NOT NULL,reason TEXT NOT NULL,payload TEXT NOT NULL)")
            db.commit()
    def _db(self):
        db=sqlite3.connect(self.path,timeout=10)
        db.execute("PRAGMA journal_mode=WAL")
        return db
    def add(self,symbol,mode,direction,confidence,approved,reason,payload):
        with self.lock,self._db() as db:
            db.execute("INSERT INTO decisions(created_ts,symbol,mode,direction,confidence,approved,reason,payload) VALUES(?,?,?,?,?,?,?,?)",
                (int(time.time()),symbol,mode,direction,float(confidence),int(bool(approved)),reason,json.dumps(payload,default=str)))
            db.commit()
    def list(self,limit=50):
        limit=max(1,min(int(limit),500))
        with self._db() as db:
            rows=db.execute("SELECT id,created_ts,symbol,mode,direction,confidence,approved,reason,payload FROM decisions ORDER BY id DESC LIMIT ?",(limit,)).fetchall()
        keys=["id","created_ts","symbol","mode","direction","confidence","approved","reason","payload"]
        out=[]
        for r in rows:
            x=dict(zip(keys,r)); x["approved"]=bool(x["approved"]); x["payload"]=json.loads(x["payload"]); out.append(x)
        return out
