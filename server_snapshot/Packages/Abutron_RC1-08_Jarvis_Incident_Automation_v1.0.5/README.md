# Abutron RC1-08 Jarvis Incident Automation v1.0.5

## Boot/transient hardening release

v1.0.5 adds two protections discovered during the real Windows reboot certification:

- `startup_grace_seconds: 90` — boot-time dependency failures are audited but do not create incidents during the short stabilization window.
- `failure_confirmations: 2` — after grace, one transient failure is held as pending evidence; a second consecutive failure is required before an incident is opened.

This specifically prevents one-off `WinError 10061` (connection refused) and `WinError 10054` (connection reset) events during Windows/Jarvis startup from becoming false CRITICAL incidents, while persistent failures still open incidents. Incident fingerprints are also normalized to the check identity, so a single `jarvis_api` outage no longer fragments into separate incidents merely because Windows alternates between reset/refused error text.

Safety remains `OBSERVE_ONLY`; approval execution remains disabled.

### Install
Run `scripts\Install-RC1-08-Boot-Hardening-v1.0.5.ps1`, reboot Windows once, then run `scripts\Certify-RC1-08-PostReboot-v1.0.5.ps1`.

---

# Abutron RC1-08 — Jarvis Incident Automation v1.0.2

Additive fail-closed incident sidecar for the existing `C:\Abutron\Jarvis` installation.

## Safety contract
RC1-08 is **OBSERVE_ONLY**. It collects health evidence, persists/deduplicates incidents, requests advisory Hermes diagnosis, creates approval records, and exposes local metrics/API endpoints. It does **not** trade, change Kronos, deploy code, restart arbitrary services, or send external messages. Telegram/WhatsApp/Meta delivery remains RC1-09.

Default bind: `127.0.0.1:8788`.

Endpoints: `/health`, `/metrics`, authenticated `/incidents`, `/approvals`, `POST /collect`, incident acknowledgement and approval/rejection. Approval changes state only; execution is disabled.


## v1.0.2 corrective changes
- Correct Kronos core health endpoint to `http://127.0.0.1:8088/health`.
- Add MT5 bridge HTTP health check on `http://127.0.0.1:8090/health`.
- Automatically cancel PENDING approvals when their incident is confirmed RECOVERED.
- Add repair helper for Prometheus/Grafana deployment mistakes.


## v1.0.5 Windows SQLite lifecycle fix

Windows exposed a test/store resource-lifecycle defect in v1.0.4: sqlite3.Connection context management commits or rolls back but does not close the database handle. On Windows, TemporaryDirectory cleanup therefore failed with WinError 32 even after test assertions completed. v1.0.5 wraps every Store connection in an explicit context manager that commits/rolls back and always closes in finally. A deterministic regression test verifies the connection is closed after leaving the context. Boot hardening from v1.0.4 is otherwise unchanged: 90-second startup grace, two-failure confirmation, stable per-check incident fingerprinting, OBSERVE_ONLY safety, and stale-approval reconciliation.
