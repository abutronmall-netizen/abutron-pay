import sqlite3
import tempfile
import unittest
from pathlib import Path

from mt5_fleet_agent.store import FleetStore


class FleetStoreSafetyTests(unittest.TestCase):
    def test_legacy_database_adds_process_create_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "legacy-fleet.db"

            db = sqlite3.connect(path)
            try:
                db.execute(
                    """
                    CREATE TABLE sessions(
                        session_id TEXT PRIMARY KEY,
                        account_id TEXT NOT NULL UNIQUE,
                        login TEXT NOT NULL,
                        server TEXT NOT NULL,
                        port INTEGER NOT NULL UNIQUE,
                        terminal_instance TEXT NOT NULL,
                        pid INTEGER,
                        status TEXT NOT NULL,
                        last_error TEXT DEFAULT ''
                    )
                    """
                )

                db.execute(
                    """
                    INSERT INTO sessions(
                        session_id,
                        account_id,
                        login,
                        server,
                        port,
                        terminal_instance,
                        pid,
                        status,
                        last_error
                    )
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        "legacy-session",
                        "account-legacy",
                        "53054439",
                        "ICMarketsSC-Demo",
                        8200,
                        "terminal-legacy",
                        12345,
                        "running",
                        "",
                    ),
                )

                db.commit()
            finally:
                db.close()

            store = FleetStore(path)
            item = store.get("legacy-session")

            self.assertIsNotNone(item)
            self.assertEqual(
                item["session_id"],
                "legacy-session",
            )
            self.assertEqual(
                item["account_id"],
                "account-legacy",
            )
            self.assertEqual(
                item["pid"],
                12345,
            )
            self.assertIsNone(
                item["process_create_time"]
            )

            verify_db = sqlite3.connect(path)
            try:
                columns = {
                    row[1]
                    for row in verify_db.execute(
                        "PRAGMA table_info(sessions)"
                    ).fetchall()
                }
            finally:
                verify_db.close()

            self.assertIn(
                "process_create_time",
                columns,
            )


    def test_list_ports_reserves_only_active_sessions(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = FleetStore(
                Path(tmp) / "fleet-test.db"
            )

            sessions = [
                {
                    "session_id": "running-session",
                    "account_id": "account-running",
                    "login": "1001",
                    "server": "ICMarketsSC-Demo",
                    "port": 8200,
                    "terminal_instance": "terminal-running",
                    "pid": 10001,
                    "status": "running",
                    "last_error": "",
                },
                {
                    "session_id": "provisioning-session",
                    "account_id": "account-provisioning",
                    "login": "1002",
                    "server": "ICMarketsSC-Demo",
                    "port": 8201,
                    "terminal_instance": "terminal-provisioning",
                    "pid": 10002,
                    "status": "provisioning",
                    "last_error": "",
                },
                {
                    "session_id": "disconnected-session",
                    "account_id": "account-disconnected",
                    "login": "1003",
                    "server": "ICMarketsSC-Demo",
                    "port": 8202,
                    "terminal_instance": "terminal-disconnected",
                    "pid": None,
                    "status": "disconnected",
                    "last_error": "",
                },
                {
                    "session_id": "error-session",
                    "account_id": "account-error",
                    "login": "1004",
                    "server": "ICMarketsSC-Demo",
                    "port": 8203,
                    "terminal_instance": "terminal-error",
                    "pid": None,
                    "status": "error",
                    "last_error": "test-only",
                },
            ]

            for item in sessions:
                store.upsert(item)

            self.assertEqual(
                store.list_ports(),
                {8200, 8201},
            )


if __name__ == "__main__":
    unittest.main()
