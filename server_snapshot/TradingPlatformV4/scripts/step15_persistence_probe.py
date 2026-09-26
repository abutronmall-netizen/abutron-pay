from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

from sqlalchemy import delete, func, inspect, select
from sqlalchemy.engine import make_url

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

os.chdir(ROOT)

from abutron.config import settings as core_settings
from abutron.platform_db import (
    AuditEvent,
    Notification,
    Subscription,
    TradeRecord,
    TradingAccount,
    User,
    License,
    engine as platform_engine,
    session_scope,
)
from abutron.storage.decisions import DecisionStore
from abutron.worker import sync_deals
from mt5_bridge.settings import settings as bridge_settings
from mt5_bridge.store import IdempotencyStore


def out(key, value):
    print(f"{key}={value}", flush=True)


def resolve_path(value: str) -> Path:
    p = Path(value)
    if not p.is_absolute():
        p = ROOT / p
    return p.resolve()


def platform_sqlite_path() -> Path:
    url = make_url(str(core_settings.platform_db_url))
    if not url.drivername.startswith("sqlite"):
        raise RuntimeError(
            f"STEP15 currently requires SQLite platform backend for the backup/restore drill; backend={url.drivername}"
        )
    if not url.database:
        raise RuntimeError("SQLite platform database path is empty.")
    return resolve_path(url.database)


def decision_db_path() -> Path:
    return resolve_path(str(core_settings.decision_db))


def bridge_db_path() -> Path:
    return resolve_path(str(bridge_settings.idempotency_db))


def sqlite_connect(path: Path):
    return sqlite3.connect(str(path), timeout=30)


def sqlite_integrity(path: Path) -> str:
    if not path.exists():
        raise RuntimeError(f"SQLite database missing: {path}")
    with sqlite_connect(path) as db:
        row = db.execute("PRAGMA integrity_check").fetchone()
    return str(row[0]) if row else ""


def sqlite_tables(path: Path) -> list[str]:
    with sqlite_connect(path) as db:
        return [
            str(r[0])
            for r in db.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table' AND name NOT LIKE 'sqlite_%' "
                "ORDER BY name"
            ).fetchall()
        ]


def qident(name: str) -> str:
    return '"' + str(name).replace('"', '""') + '"'


def sqlite_table_counts(path: Path) -> dict[str, int]:
    result = {}
    with sqlite_connect(path) as db:
        for table in sqlite_tables(path):
            row = db.execute(f"SELECT COUNT(*) FROM {qident(table)}").fetchone()
            result[table] = int(row[0]) if row else 0
    return result


def marker_count_sqlite(path: Path, marker: str) -> int:
    total = 0
    with sqlite_connect(path) as db:
        for table in sqlite_tables(path):
            cols = [
                str(r[1])
                for r in db.execute(
                    f"PRAGMA table_info({qident(table)})"
                ).fetchall()
            ]
            if not cols:
                continue
            where = " OR ".join(
                f"CAST({qident(c)} AS TEXT) LIKE ?" for c in cols
            )
            params = [f"%{marker}%"] * len(cols)
            row = db.execute(
                f"SELECT COUNT(*) FROM {qident(table)} WHERE {where}",
                params,
            ).fetchone()
            total += int(row[0]) if row else 0
    return total


def delete_marker_sqlite(path: Path, marker: str) -> int:
    deleted = 0
    with sqlite_connect(path) as db:
        for table in sqlite_tables(path):
            cols = [
                str(r[1])
                for r in db.execute(
                    f"PRAGMA table_info({qident(table)})"
                ).fetchall()
            ]
            if not cols:
                continue
            where = " OR ".join(
                f"CAST({qident(c)} AS TEXT) LIKE ?" for c in cols
            )
            params = [f"%{marker}%"] * len(cols)
            cur = db.execute(
                f"DELETE FROM {qident(table)} WHERE {where}",
                params,
            )
            if cur.rowcount and cur.rowcount > 0:
                deleted += int(cur.rowcount)
        db.commit()
    return deleted


def sqlite_backup(source: Path, dest: Path):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    with sqlite_connect(source) as src, sqlite_connect(dest) as dst:
        src.backup(dst)
        dst.commit()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def platform_counts() -> dict[str, int]:
    names = (
        "users",
        "trading_accounts",
        "licenses",
        "subscriptions",
        "trade_records",
        "notifications",
        "audit_events",
    )
    insp = inspect(platform_engine)
    existing = set(insp.get_table_names())
    result = {}
    with platform_engine.connect() as conn:
        for name in names:
            if name not in existing:
                raise RuntimeError(f"Required platform table missing: {name}")
            result[name] = int(
                conn.exec_driver_sql(
                    f"SELECT COUNT(*) FROM {qident(name)}"
                ).scalar_one()
            )
    return result


def audit_count(action: str, subject: str) -> int:
    with session_scope() as s:
        return int(
            s.scalar(
                select(func.count())
                .select_from(AuditEvent)
                .where(
                    AuditEvent.action == action,
                    AuditEvent.subject == subject,
                )
            )
            or 0
        )


def trade_marker_count(ticket: str) -> int:
    with session_scope() as s:
        return int(
            s.scalar(
                select(func.count())
                .select_from(TradeRecord)
                .where(
                    TradeRecord.ticket == ticket,
                    TradeRecord.state == "OPENED",
                )
            )
            or 0
        )


def make_ticket(marker: str) -> str:
    digest = hashlib.sha256(marker.encode("utf-8")).hexdigest()
    # Numeric string only, to mirror broker-ticket shape while being
    # recognizably outside the real broker path.
    return str(990000000000 + (int(digest[:10], 16) % 9000000000))


def create_markers(marker: str):
    store = DecisionStore()
    payload = {
        "step15_marker": marker,
        "certification": True,
        "note": "synthetic persistence marker; no broker execution",
    }
    store.add(
        f"STEP15_{marker[-12:]}",
        "FUSION",
        "HOLD",
        0.0,
        False,
        "STEP15_CERTIFICATION",
        payload,
    )

    decision_count = marker_count_sqlite(decision_db_path(), marker)
    if decision_count < 1:
        raise RuntimeError("DecisionStore marker was not persisted.")

    if audit_count("STEP15_PERSISTENCE_PROBE", marker) == 0:
        with session_scope() as s:
            s.add(
                AuditEvent(
                    actor="step15-cert",
                    action="STEP15_PERSISTENCE_PROBE",
                    subject=marker,
                    detail="Synthetic persistence marker. No trading action.",
                )
            )

    ticket = make_ticket(marker)
    fake_deal = {
        "ticket": int(ticket),
        "entry": 0,
        "type": 0,
        "symbol": "STEP15CERT",
        "volume": 0.0,
        "price": 0.0,
        "profit": 0.0,
        "commission": 0.0,
        "swap": 0.0,
        "time": int(time.time()),
    }

    # Run reconciliation twice. The second call must not duplicate the row.
    sync_deals([fake_deal])
    sync_deals([fake_deal])

    tc = trade_marker_count(ticket)
    if tc != 1:
        raise RuntimeError(
            f"sync_deals idempotency failed for certification row; count={tc}"
        )

    bridge_store = IdempotencyStore()
    if not hasattr(bridge_store, "claim"):
        raise RuntimeError("Bridge execution-claim hardening is missing.")
    if not hasattr(bridge_store, "claim_exists"):
        raise RuntimeError("Bridge claim_exists hardening is missing.")
    if not hasattr(bridge_store, "release_claim"):
        raise RuntimeError("Bridge release_claim hardening is missing.")

    claim_key = "STEP15:" + marker
    if bridge_store.claim_exists(claim_key):
        bridge_store.release_claim(claim_key)

    first = bool(bridge_store.claim(claim_key))
    second = bool(bridge_store.claim(claim_key))

    if not first:
        raise RuntimeError("Initial bridge execution claim was not acquired.")
    if second:
        raise RuntimeError("Duplicate bridge execution claim was incorrectly acquired.")
    if not bridge_store.claim_exists(claim_key):
        raise RuntimeError("Bridge execution claim was not persisted.")

    out("DECISION_MARKER_PERSISTED", "PASS")
    out("AUDIT_MARKER_PERSISTED", "PASS")
    out("SYNC_DEALS_DUPLICATE_SUPPRESSION", "PASS")
    out("TRADE_MARKER_TICKET", ticket)
    out("BRIDGE_CLAIM_FIRST", first)
    out("BRIDGE_CLAIM_DUPLICATE_BLOCKED", not second)
    out("BRIDGE_CLAIM_PERSISTED", "PASS")


def verify_markers(marker: str):
    dc = marker_count_sqlite(decision_db_path(), marker)
    ac = audit_count("STEP15_PERSISTENCE_PROBE", marker)
    tc = trade_marker_count(make_ticket(marker))
    claim_key = "STEP15:" + marker
    bridge_store = IdempotencyStore()
    cc = bool(bridge_store.claim_exists(claim_key))

    out("DECISION_MARKER_COUNT", dc)
    out("AUDIT_MARKER_COUNT", ac)
    out("TRADE_MARKER_COUNT", tc)
    out("BRIDGE_CLAIM_EXISTS", cc)

    if dc < 1:
        raise RuntimeError("Decision marker did not survive restart.")
    if ac != 1:
        raise RuntimeError(f"Audit marker count invalid after restart: {ac}")
    if tc != 1:
        raise RuntimeError(f"Trade reconciliation marker count invalid after restart: {tc}")
    if not cc:
        raise RuntimeError("Bridge execution claim did not survive restart.")

    out("PERSISTENCE_AFTER_RESTART", "PASS")


def cleanup_markers(marker: str):
    deleted_decisions = delete_marker_sqlite(decision_db_path(), marker)

    with session_scope() as s:
        s.execute(
            delete(TradeRecord).where(
                TradeRecord.ticket == make_ticket(marker),
                TradeRecord.state == "OPENED",
            )
        )
        s.execute(
            delete(AuditEvent).where(
                AuditEvent.action == "STEP15_PERSISTENCE_PROBE",
                AuditEvent.subject == marker,
            )
        )

    bridge_store = IdempotencyStore()
    bridge_store.release_claim("STEP15:" + marker)

    out("DECISION_MARKERS_DELETED", deleted_decisions)
    out("SYNTHETIC_TRADE_MARKER_CLEANED", "PASS")
    out("PERSISTENCE_PROBE_AUDIT_CLEANED", "PASS")
    out("BRIDGE_CLAIM_CLEANED", "PASS")


def final_audit(marker: str):
    if audit_count("STEP15_CERTIFIED", marker) == 0:
        with session_scope() as s:
            s.add(
                AuditEvent(
                    actor="step15-cert",
                    action="STEP15_CERTIFIED",
                    subject=marker,
                    detail=(
                        "Database/audit persistence, restart reconciliation, "
                        "idempotency and SQLite restore drill passed. "
                        "No trading action performed."
                    ),
                )
            )

    count = audit_count("STEP15_CERTIFIED", marker)
    if count != 1:
        raise RuntimeError(f"Final STEP15_CERTIFIED audit count invalid: {count}")

    out("FINAL_AUDIT_EVENT", "PASS")


def verify_final(marker: str):
    dc = marker_count_sqlite(decision_db_path(), marker)
    tc = trade_marker_count(make_ticket(marker))
    probe_ac = audit_count("STEP15_PERSISTENCE_PROBE", marker)
    cert_ac = audit_count("STEP15_CERTIFIED", marker)
    claim_exists = bool(
        IdempotencyStore().claim_exists("STEP15:" + marker)
    )

    out("FINAL_DECISION_MARKER_COUNT", dc)
    out("FINAL_TRADE_MARKER_COUNT", tc)
    out("FINAL_PROBE_AUDIT_COUNT", probe_ac)
    out("FINAL_CERT_AUDIT_COUNT", cert_ac)
    out("FINAL_BRIDGE_CLAIM_EXISTS", claim_exists)

    if dc != 0:
        raise RuntimeError("Synthetic decision marker cleanup failed.")
    if tc != 0:
        raise RuntimeError("Synthetic trade marker cleanup failed.")
    if probe_ac != 0:
        raise RuntimeError("Synthetic probe audit cleanup failed.")
    if cert_ac != 1:
        raise RuntimeError("Final audit certification event missing.")
    if claim_exists:
        raise RuntimeError("Synthetic bridge claim cleanup failed.")

    out("SYNTHETIC_STATE_CLEANUP", "PASS")
    out("AUDIT_CERTIFICATION_RETAINED", "PASS")


def backup_restore_drill(marker: str, backup_dir: Path):
    paths = {
        "decision": decision_db_path(),
        "platform": platform_sqlite_path(),
        "bridge": bridge_db_path(),
    }

    for name, src in paths.items():
        if sqlite_integrity(src).lower() != "ok":
            raise RuntimeError(f"{name} live SQLite integrity check failed.")

    live_counts = {
        name: sqlite_table_counts(path)
        for name, path in paths.items()
    }

    backup_dir.mkdir(parents=True, exist_ok=True)
    restore_dir = backup_dir / "restore_drill"
    restore_dir.mkdir(parents=True, exist_ok=True)

    for name, src in paths.items():
        backup_path = backup_dir / f"{name}.sqlite3"
        restore_path = restore_dir / f"{name}.sqlite3"

        sqlite_backup(src, backup_path)
        sqlite_backup(backup_path, restore_path)

        if sqlite_integrity(backup_path).lower() != "ok":
            raise RuntimeError(f"{name} backup integrity check failed.")
        if sqlite_integrity(restore_path).lower() != "ok":
            raise RuntimeError(f"{name} restored-copy integrity check failed.")

        restore_counts = sqlite_table_counts(restore_path)
        if restore_counts != live_counts[name]:
            raise RuntimeError(
                f"{name} restored-copy table-count mismatch."
            )

        out(f"{name.upper()}_BACKUP_SHA256", sha256(backup_path))
        out(f"{name.upper()}_RESTORE_SHA256", sha256(restore_path))
        out(f"{name.upper()}_RESTORE_COUNT_PARITY", "PASS")

    out("SQLITE_BACKUP_RESTORE_DRILL", "PASS")


def inventory():
    dp = decision_db_path()
    pp = platform_sqlite_path()
    bp = bridge_db_path()

    for name, path in (
        ("decision", dp),
        ("platform", pp),
        ("bridge", bp),
    ):
        result = sqlite_integrity(path)
        out(f"{name.upper()}_DB_INTEGRITY", result)
        if result.lower() != "ok":
            raise RuntimeError(f"{name} database integrity failed.")

    ptables = set(inspect(platform_engine).get_table_names())
    required = {
        "users",
        "trading_accounts",
        "licenses",
        "subscriptions",
        "trade_records",
        "notifications",
        "audit_events",
    }
    missing = sorted(required - ptables)
    if missing:
        raise RuntimeError("Platform tables missing: " + ",".join(missing))

    bridge_tables = set(sqlite_tables(bp))
    required_bridge = {"executions", "execution_claims", "position_meta"}
    missing_bridge = sorted(required_bridge - bridge_tables)
    if missing_bridge:
        raise RuntimeError(
            "Bridge persistence tables missing: " + ",".join(missing_bridge)
        )

    decision_tables = sqlite_tables(dp)
    if not decision_tables:
        raise RuntimeError("Decision database has no tables.")

    out("PLATFORM_DB_BACKEND", "sqlite")
    out("PLATFORM_REQUIRED_TABLES", "PASS")
    out("BRIDGE_PERSISTENCE_TABLES", "PASS")
    out("DECISION_DB_TABLES_PRESENT", "PASS")

    counts = platform_counts()
    for key, value in counts.items():
        out("PLATFORM_COUNT_" + key.upper(), value)


def mt5_snapshot(mt5_path: str, start_epoch: int):
    import MetaTrader5 as mt5

    ok = mt5.initialize(path=mt5_path)
    out("MT5_PROBE_INIT", bool(ok))
    if not ok:
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    try:
        ti = mt5.terminal_info()
        ai = mt5.account_info()
        if not (ti and ti.connected and ai):
            raise RuntimeError("MT5 is not connected.")

        expected = str(getattr(bridge_settings, "expected_server", "") or "")
        if expected and str(ai.server) != expected:
            raise RuntimeError("MT5 expected server mismatch.")

        magic = int(getattr(bridge_settings, "magic", 400040))
        positions = mt5.positions_get()
        if positions is None:
            raise RuntimeError("MT5 positions query failed.")

        magic_positions = [
            p for p in positions
            if int(getattr(p, "magic", 0) or 0) == magic
        ]

        from datetime import datetime, timezone

        deals = mt5.history_deals_get(
            datetime.fromtimestamp(start_epoch, tz=timezone.utc),
            datetime.now(timezone.utc),
        )
        if deals is None:
            raise RuntimeError("MT5 history query failed.")

        magic_deals = [
            d for d in deals
            if int(getattr(d, "magic", 0) or 0) == magic
        ]

        out("MT5_CONNECTED", True)
        out("MT5_TERMINAL_TRADE_ALLOWED", bool(ti.trade_allowed))
        out("MT5_ABUTRON_MAGIC_POSITIONS", len(magic_positions))
        out("MT5_ABUTRON_MAGIC_DEALS_SINCE_START", len(magic_deals))

        # Step 15 is deliberately a zero-state restart reconciliation gate.
        # Open-position/ticket reconciliation is certified later in the
        # broker demo lifecycle once real Abutron demo positions exist.
        if magic_positions:
            raise RuntimeError(
                "Step 15 requires zero current Abutron-magic positions."
            )
        if magic_deals:
            raise RuntimeError(
                "Abutron-magic deals appeared during Step 15."
            )

        out("MT5_ZERO_STATE_RECONCILIATION", "PASS")
    finally:
        mt5.shutdown()


def cmd_preflight(args):
    inventory()
    create_markers(args.marker)
    backup_restore_drill(args.marker, Path(args.backup_dir))
    mt5_snapshot(args.mt5_path, args.start_epoch)
    out("STEP15_HELPER_PREFLIGHT", "PASS")


def cmd_verify(args):
    inventory()
    verify_markers(args.marker)
    mt5_snapshot(args.mt5_path, args.start_epoch)
    out("STEP15_HELPER_POST_RESTART_VERIFY", "PASS")


def cmd_cleanup(args):
    cleanup_markers(args.marker)
    out("STEP15_HELPER_CLEANUP", "PASS")


def cmd_final_audit(args):
    final_audit(args.marker)
    out("STEP15_HELPER_FINAL_AUDIT", "PASS")


def cmd_verify_final(args):
    inventory()
    verify_final(args.marker)
    mt5_snapshot(args.mt5_path, args.start_epoch)
    out("STEP15_HELPER_FINAL_VERIFY", "PASS")


def main():
    p = argparse.ArgumentParser()
    p.add_argument(
        "command",
        choices=(
            "preflight",
            "verify",
            "cleanup",
            "final-audit",
            "verify-final",
        ),
    )
    p.add_argument("--marker", required=True)
    p.add_argument("--backup-dir", default="")
    p.add_argument("--mt5-path", required=True)
    p.add_argument("--start-epoch", required=True, type=int)
    args = p.parse_args()

    if args.command == "preflight":
        if not args.backup_dir:
            raise RuntimeError("--backup-dir is required for preflight.")
        cmd_preflight(args)
    elif args.command == "verify":
        cmd_verify(args)
    elif args.command == "cleanup":
        cmd_cleanup(args)
    elif args.command == "final-audit":
        cmd_final_audit(args)
    elif args.command == "verify-final":
        cmd_verify_final(args)


if __name__ == "__main__":
    main()
