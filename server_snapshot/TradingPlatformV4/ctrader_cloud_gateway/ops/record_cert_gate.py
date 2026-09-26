from __future__ import annotations
import argparse,json,sqlite3,time
from pathlib import Path

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--db',required=True); p.add_argument('--user-id',required=True); p.add_argument('--account-id',type=int,required=True); p.add_argument('--gate',required=True); p.add_argument('--detail',default='{}')
    a=p.parse_args(); detail=json.loads(a.detail); now=int(time.time()); db=Path(a.db)
    if not db.exists(): raise RuntimeError('CERT_GATE_DB_MISSING')
    with sqlite3.connect(db) as c:
        tables={x[0] for x in c.execute("select name from sqlite_master where type='table'")}
        if 'certification_gate' not in tables: raise RuntimeError('CERT_GATE_TABLE_MISSING')
        c.execute("""insert into certification_gate(user_id,ctid_account_id,gate,status,detail_json,updated_at)
        values(?,?,?,?,?,?) on conflict(user_id,ctid_account_id,gate) do update set status=excluded.status,detail_json=excluded.detail_json,updated_at=excluded.updated_at""",
        (str(a.user_id),int(a.account_id),str(a.gate),'PASS',json.dumps(detail,separators=(',',':')),now)); c.commit()
    print(f'{a.gate}=RECORDED_PASS')
if __name__=='__main__': main()
