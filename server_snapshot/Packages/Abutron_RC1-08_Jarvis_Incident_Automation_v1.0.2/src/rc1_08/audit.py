import json, threading
from datetime import datetime, timezone
from pathlib import Path
_lock=threading.Lock()
def write_audit(path,event,payload):
    rec={'ts':datetime.now(timezone.utc).isoformat(),'event':event,'payload':payload}
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with _lock,p.open('a',encoding='utf-8') as f: f.write(json.dumps(rec,separators=(',',':'),default=str)+'\n')
