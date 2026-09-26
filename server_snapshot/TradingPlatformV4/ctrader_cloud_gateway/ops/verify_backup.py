from __future__ import annotations
import argparse, hashlib, json, sqlite3
from pathlib import Path

def sha256(path: Path) -> str:
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
    return h.hexdigest().upper()

def main():
    p=argparse.ArgumentParser(); p.add_argument('--manifest',required=True); a=p.parse_args()
    mp=Path(a.manifest); data=json.loads(mp.read_text(encoding='utf-8'))
    if not data.get('items'): raise RuntimeError('BACKUP_MANIFEST_EMPTY')
    sqlite_count=0
    for item in data['items']:
        path=Path(item['backup'])
        if not path.exists(): raise RuntimeError(f'BACKUP_FILE_MISSING:{path}')
        if sha256(path)!=item['sha256']: raise RuntimeError(f'BACKUP_HASH_MISMATCH:{path}')
        if item['kind']=='sqlite':
            sqlite_count+=1
            with sqlite3.connect(str(path)) as c:
                row=c.execute('PRAGMA integrity_check').fetchone()
                if not row or str(row[0]).lower()!='ok': raise RuntimeError(f'BACKUP_SQLITE_INTEGRITY_FAIL:{path}')
    if sqlite_count < 1: raise RuntimeError('BACKUP_SQLITE_REQUIRED')
    deferred=data.get('deferred') or []
    ctrader_ok=any(x.get('label')=='CTRADER_DB' for x in data['items'])
    print('STEP22_BACKUP_VERIFY=PASS')
    print(f'STEP22_BACKUP_VERIFIED_ITEMS={len(data["items"])}')
    print(f'STEP22_BACKUP_VERIFIED_SQLITE={sqlite_count}')
    print('CTRADER_DB_BACKUP_VERIFY=' + ('PASS' if ctrader_ok else 'DEFERRED_NO_DB'))
    print(f'STEP22_BACKUP_DEFERRED_COUNT={len(deferred)}')
if __name__=='__main__': main()
