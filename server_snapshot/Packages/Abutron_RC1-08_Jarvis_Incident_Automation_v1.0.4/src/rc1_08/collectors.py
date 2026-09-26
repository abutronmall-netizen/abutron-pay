import os, shutil, subprocess, urllib.request
from dataclasses import dataclass
from pathlib import Path
@dataclass
class CheckResult: name:str; ok:bool; severity:str; summary:str; evidence:dict
def clean(s,n=2000): return (s or '')[:n].replace('\x00','')
def run_check(s):
    t=s['type']; name=s['name']; sev=str(s.get('severity','HIGH')).upper()
    try:
        if t=='url':
            with urllib.request.urlopen(urllib.request.Request(s['url'],headers={'User-Agent':'Abutron-Jarvis-RC1-08/1.0'}),timeout=float(s.get('timeout',5))) as r:
                body=r.read(4096).decode('utf-8','replace'); ok=200<=int(r.status)<300; return CheckResult(name,ok,sev,f'HTTP {r.status} {name}',{'url':s['url'],'status':r.status,'body':clean(body)})
        if t=='process':
            proc=s['process_name']
            cp=subprocess.run(['tasklist','/FI',f'IMAGENAME eq {proc}','/FO','CSV','/NH'] if os.name=='nt' else ['pgrep','-f',proc],capture_output=True,text=True,timeout=10)
            ok=(proc.lower() in cp.stdout.lower()) if os.name=='nt' else cp.returncode==0; return CheckResult(name,ok,sev,f'{proc} '+('running' if ok else 'not found'),{'process_name':proc,'output':clean(cp.stdout,1000)})
        if t=='disk':
            total,used,free=shutil.disk_usage(s['path']); pct=free/total*100 if total else 0; minimum=float(s.get('minimum_free_percent',10)); return CheckResult(name,pct>=minimum,sev,f'disk free {pct:.1f}%',{'path':s['path'],'free_percent':round(pct,2),'minimum_free_percent':minimum})
        if t=='file':
            p=Path(s['path']); ok=p.is_file(); return CheckResult(name,ok,sev,f'{p} '+('present' if ok else 'missing'),{'path':str(p),'exists':p.exists(),'size_bytes':p.stat().st_size if ok else None})
        if t=='command':
            cmd=[str(x) for x in s['command']]; cp=subprocess.run(cmd,capture_output=True,text=True,timeout=float(s.get('timeout',15)),shell=False); return CheckResult(name,cp.returncode==0,sev,f'command rc={cp.returncode}',{'command':[Path(cmd[0]).name]+cmd[1:],'returncode':cp.returncode,'stdout':clean(cp.stdout),'stderr':clean(cp.stderr)})
        raise ValueError('unsupported check '+t)
    except Exception as e: return CheckResult(name,False,sev,f'{name} check failed: {type(e).__name__}',{'error_type':type(e).__name__,'error':clean(str(e),1000)})
