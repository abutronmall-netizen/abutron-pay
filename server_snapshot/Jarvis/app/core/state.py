import sqlite3
from pathlib import Path
from app.core.settings import settings
SCHEMA='''CREATE TABLE IF NOT EXISTS incidents(id INTEGER PRIMARY KEY,created_at TEXT DEFAULT CURRENT_TIMESTAMP,severity TEXT,status TEXT,summary TEXT,evidence TEXT);CREATE TABLE IF NOT EXISTS approvals(id INTEGER PRIMARY KEY,created_at TEXT DEFAULT CURRENT_TIMESTAMP,action TEXT,payload TEXT,status TEXT DEFAULT 'PENDING');'''
def init_db():
 p=Path(settings.jarvis_state_db);p.parent.mkdir(parents=True,exist_ok=True)
 with sqlite3.connect(p) as d:d.executescript(SCHEMA)
