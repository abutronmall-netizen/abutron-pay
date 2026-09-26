import json, os
from dataclasses import dataclass
from pathlib import Path
SEVERITY_RANK={"INFO":10,"LOW":20,"MEDIUM":30,"HIGH":40,"CRITICAL":50}
@dataclass(frozen=True)
class Config:
    raw:dict
    path:Path
    @property
    def mode(self): return str(self.raw.get('mode','OBSERVE_ONLY')).upper()
    @property
    def interval_seconds(self): return max(5,int(self.raw.get('interval_seconds',30)))
    @property
    def recovery_confirmations(self): return max(1,int(self.raw.get('recovery_confirmations',2)))
    @property
    def failure_confirmations(self): return max(1,int(self.raw.get('failure_confirmations',2)))
    @property
    def startup_grace_seconds(self): return max(0,int(self.raw.get('startup_grace_seconds',90)))
    @property
    def token(self): return os.environ.get('JARVIS_API_TOKEN','')
def load_config(path):
    p=Path(path); raw=json.loads(p.read_text(encoding='utf-8-sig'))
    if str(raw.get('mode','OBSERVE_ONLY')).upper()!='OBSERVE_ONLY': raise RuntimeError('RC1-08 v1.0.0 is OBSERVE_ONLY only')
    return Config(raw,p)
