from __future__ import annotations
import json, sqlite3, time
from contextlib import contextmanager
from pathlib import Path
from typing import Any
from .config import settings

SCHEMA = """
CREATE TABLE IF NOT EXISTS oauth_state(
 state TEXT PRIMARY KEY,user_id TEXT NOT NULL,created_at INTEGER NOT NULL,used_at INTEGER);
CREATE TABLE IF NOT EXISTS oauth_token(
 user_id TEXT PRIMARY KEY,access_token_enc TEXT NOT NULL,refresh_token_enc TEXT NOT NULL,
 expires_at INTEGER NOT NULL,scope TEXT NOT NULL,updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS linked_account(
 user_id TEXT NOT NULL,ctid_account_id INTEGER NOT NULL,trader_login INTEGER,broker_title TEXT,
 environment TEXT NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(user_id,ctid_account_id));
CREATE TABLE IF NOT EXISTS idempotency(
 idempotency_key TEXT PRIMARY KEY,user_id TEXT NOT NULL,ctid_account_id INTEGER NOT NULL,
 request_hash TEXT NOT NULL,status TEXT NOT NULL,response_json TEXT,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS audit_event(
 id INTEGER PRIMARY KEY AUTOINCREMENT,event_type TEXT NOT NULL,user_id TEXT,ctid_account_id INTEGER,
 detail_json TEXT NOT NULL,created_at INTEGER NOT NULL);
"""

def _path() -> Path:
    p=Path(settings.database_path); p.parent.mkdir(parents=True, exist_ok=True); return p

@contextmanager
def connection(immediate: bool=False):
    con=sqlite3.connect(_path(), timeout=15)
    con.row_factory=sqlite3.Row
    try:
        if immediate: con.execute('BEGIN IMMEDIATE')
        yield con
        con.commit()
    except Exception:
        con.rollback(); raise
    finally:
        con.close()

def init_db():
    with connection() as con: con.executescript(SCHEMA)

def create_state(state,user_id):
    with connection() as con:
        con.execute('INSERT INTO oauth_state(state,user_id,created_at,used_at) VALUES(?,?,?,NULL)',(state,str(user_id),int(time.time())))

def get_state(state,max_age):
    now=int(time.time())
    with connection() as con:
        row=con.execute('SELECT * FROM oauth_state WHERE state=?',(state,)).fetchone()
        if not row: raise ValueError('OAUTH_TICKET_UNKNOWN')
        if row['used_at'] is not None: raise ValueError('OAUTH_TICKET_REPLAY')
        if now-int(row['created_at'])>max_age: raise ValueError('OAUTH_TICKET_EXPIRED')
        return str(row['user_id'])

def consume_state(state,max_age):
    now=int(time.time())
    with connection(immediate=True) as con:
        row=con.execute('SELECT * FROM oauth_state WHERE state=?',(state,)).fetchone()
        if not row: raise ValueError('OAUTH_TICKET_UNKNOWN')
        if row['used_at'] is not None: raise ValueError('OAUTH_TICKET_REPLAY')
        if now-int(row['created_at'])>max_age: raise ValueError('OAUTH_TICKET_EXPIRED')
        con.execute('UPDATE oauth_state SET used_at=? WHERE state=?',(now,state))
        return str(row['user_id'])

def upsert_token(user_id,access_enc,refresh_enc,expires_at,scope):
    now=int(time.time())
    with connection() as con:
        con.execute("""INSERT INTO oauth_token(user_id,access_token_enc,refresh_token_enc,expires_at,scope,updated_at)
        VALUES(?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET access_token_enc=excluded.access_token_enc,
        refresh_token_enc=excluded.refresh_token_enc,expires_at=excluded.expires_at,scope=excluded.scope,updated_at=excluded.updated_at""",
        (str(user_id),access_enc,refresh_enc,int(expires_at),str(scope),now))

def get_token(user_id):
    with connection() as con: return con.execute('SELECT * FROM oauth_token WHERE user_id=?',(str(user_id),)).fetchone()

def delete_link(user_id):
    with connection(immediate=True) as con:
        con.execute('DELETE FROM oauth_token WHERE user_id=?',(str(user_id),))
        con.execute('DELETE FROM linked_account WHERE user_id=?',(str(user_id),))

def replace_accounts(user_id, accounts:list[dict[str,Any]]):
    now=int(time.time())
    with connection(immediate=True) as con:
        con.execute('DELETE FROM linked_account WHERE user_id=?',(str(user_id),))
        for a in accounts:
            con.execute("""INSERT INTO linked_account(user_id,ctid_account_id,trader_login,broker_title,environment,updated_at)
            VALUES(?,?,?,?,?,?)""",(str(user_id),int(a['ctid_account_id']),int(a['trader_login']) if a.get('trader_login') is not None else None,
            a.get('broker_title'),str(a['environment']).upper(),now))

def list_accounts(user_id):
    with connection() as con:
        return [dict(r) for r in con.execute('SELECT ctid_account_id,trader_login,broker_title,environment,updated_at FROM linked_account WHERE user_id=? ORDER BY environment,ctid_account_id',(str(user_id),)).fetchall()]

def get_account(user_id, account_id):
    with connection() as con: return con.execute('SELECT * FROM linked_account WHERE user_id=? AND ctid_account_id=?',(str(user_id),int(account_id))).fetchone()

def reserve_idempotency(key,user_id,account_id,request_hash):
    now=int(time.time())
    with connection(immediate=True) as con:
        row=con.execute('SELECT * FROM idempotency WHERE idempotency_key=?',(key,)).fetchone()
        if row:
            if row['request_hash']!=request_hash: return {'state':'CONFLICT'}
            if row['status']=='COMPLETED': return {'state':'REPLAY','response_json':row['response_json']}
            return {'state':row['status']}
        con.execute("""INSERT INTO idempotency(idempotency_key,user_id,ctid_account_id,request_hash,status,response_json,created_at,updated_at)
        VALUES(?,?,?,?,'PENDING',NULL,?,?)""",(key,str(user_id),int(account_id),request_hash,now,now))
        return {'state':'RESERVED'}

def complete_idempotency(key,response):
    now=int(time.time())
    with connection(immediate=True) as con:
        con.execute('UPDATE idempotency SET status=\'COMPLETED\',response_json=?,updated_at=? WHERE idempotency_key=?',(json.dumps(response,separators=(',',':')),now,key))

def mark_uncertain(key,detail):
    now=int(time.time())
    with connection(immediate=True) as con:
        con.execute('UPDATE idempotency SET status=\'UNCERTAIN\',response_json=?,updated_at=? WHERE idempotency_key=?',(json.dumps({'error':str(detail)},separators=(',',':')),now,key))

def audit(event_type,user_id=None,account_id=None,**detail):
    with connection() as con:
        con.execute('INSERT INTO audit_event(event_type,user_id,ctid_account_id,detail_json,created_at) VALUES(?,?,?,?,?)',
                    (event_type,str(user_id) if user_id is not None else None,int(account_id) if account_id is not None else None,json.dumps(detail,separators=(',',':')),int(time.time())))
