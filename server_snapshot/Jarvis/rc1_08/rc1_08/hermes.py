import json, os, re, subprocess, tempfile
from pathlib import Path
def extract_json(t):
    t=t.strip()
    try: return json.loads(t)
    except Exception: pass
    m=re.search(r'\{.*\}',t,re.S)
    if not m: raise ValueError('Hermes returned no JSON object')
    return json.loads(m.group(0))
class HermesDiagnostic:
    def __init__(self,cfg): self.cfg=cfg
    def diagnose(self,incident):
        if not self.cfg.get('enabled',True): return {'status':'DISABLED','summary':'Hermes diagnostics disabled'}
        sb=Path(self.cfg['sandbox_dir']); sb.mkdir(parents=True,exist_ok=True)
        prompt=("You are the advisory diagnostics worker for Abutron Jarvis RC1-08. You are NOT authorized to execute tools, modify files, restart services, trade, deploy, or contact external systems. Analyze ONLY the supplied evidence. Return exactly one JSON object with keys summary, probable_cause, confidence, risk, evidence, recommended_action, requires_human. recommended_action.type must be one of NONE, COLLECT_MORE_EVIDENCE, RESTART_ABUTRON_WORKER, RESTART_MT5_BRIDGE, RUN_HEALTH_CHECK, RUN_RECONCILIATION. If evidence is insufficient use COLLECT_MORE_EVIDENCE. INCIDENT_EVIDENCE: "+json.dumps(incident,separators=(',',':'),default=str))
        fd,p=tempfile.mkstemp(prefix='rc1_08_',suffix='.txt',dir=sb); os.close(fd); pp=Path(p); pp.write_text(prompt,encoding='utf-8')
        env=os.environ.copy()
        if self.cfg.get('home'): env['HERMES_HOME']=str(self.cfg['home'])
        try:
            cp=subprocess.run([str(self.cfg['exe']),'chat','--safe-mode','--quiet','--max-turns','1','--query-file',str(pp)],capture_output=True,text=True,timeout=float(self.cfg.get('timeout_seconds',120)),cwd=sb,env=env,shell=False)
            if cp.returncode: raise RuntimeError(f'Hermes rc={cp.returncode}: {(cp.stderr or cp.stdout)[:1000]}')
            out=extract_json(cp.stdout); out['status']='OK'; return out
        finally:
            try: pp.unlink(missing_ok=True)
            except Exception: pass
