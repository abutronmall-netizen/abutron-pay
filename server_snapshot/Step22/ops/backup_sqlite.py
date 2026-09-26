from __future__ import annotations
import argparse, hashlib, json, shutil, sqlite3, time
from pathlib import Path


def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):
            h.update(chunk)
    return h.hexdigest().upper()


def sqlite_backup(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True,exist_ok=True)
    with sqlite3.connect(str(src)) as s, sqlite3.connect(str(dst)) as d:
        s.backup(d)
    with sqlite3.connect(str(dst)) as c:
        row=c.execute('PRAGMA integrity_check').fetchone()
        if not row or str(row[0]).lower()!='ok':
            raise RuntimeError(f'SQLITE_INTEGRITY_FAIL:{src}')


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--root',required=True)
    p.add_argument('--output',required=True)
    p.add_argument('--caddyfile',default='')
    a=p.parse_args()
    root=Path(a.root); out=Path(a.output); out.mkdir(parents=True,exist_ok=True)
    items=[]
    dbs=[
        root/'data'/'abutron_platform.db',
        root/'data'/'abutron_decisions.db',
        root/'data'/'mt5_idempotency.db',
        root/'ctrader_cloud_gateway'/'data'/'ctrader_gateway.db',
    ]
    for src in dbs:
        if src.exists():
            dst=out/'sqlite'/src.name
            sqlite_backup(src,dst)
            items.append({'kind':'sqlite','source':str(src),'backup':str(dst),'sha256':sha256(dst),'size':dst.stat().st_size})
    files=[root/'.env', root/'ctrader_cloud_gateway'/'.env']
    if a.caddyfile:
        files.append(Path(a.caddyfile))
    for src in files:
        if src.exists():
            dst=out/'files'/src.name
            if dst.exists(): dst=out/'files'/f'{src.parent.name}_{src.name}'
            dst.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(src,dst)
            items.append({'kind':'file','source':str(src),'backup':str(dst),'sha256':sha256(dst),'size':dst.stat().st_size})
    if not any(x['source'].endswith('ctrader_gateway.db') for x in items):
        raise RuntimeError('CTRADER_DB_BACKUP_MISSING')
    manifest={'created_unix':int(time.time()),'root':str(root),'items':items}
    mp=out/'backup_manifest.json'; mp.write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print('STEP22_BACKUP_CREATED=PASS')
    print(f'STEP22_BACKUP_ITEM_COUNT={len(items)}')
    print(f'STEP22_BACKUP_MANIFEST={mp}')

if __name__=='__main__': main()
