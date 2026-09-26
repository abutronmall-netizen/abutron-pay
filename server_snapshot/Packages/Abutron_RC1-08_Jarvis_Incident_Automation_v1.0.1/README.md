# Abutron RC1-08 — Jarvis Incident Automation v1.0.1

Additive fail-closed incident sidecar for the existing `C:\Abutron\Jarvis` installation.

## Safety contract
RC1-08 is **OBSERVE_ONLY**. It collects health evidence, persists/deduplicates incidents, requests advisory Hermes diagnosis, creates approval records, and exposes local metrics/API endpoints. It does **not** trade, change Kronos, deploy code, restart arbitrary services, or send external messages. Telegram/WhatsApp/Meta delivery remains RC1-09.

Default bind: `127.0.0.1:8788`.

Endpoints: `/health`, `/metrics`, authenticated `/incidents`, `/approvals`, `POST /collect`, incident acknowledgement and approval/rejection. Approval changes state only; execution is disabled.


## v1.0.1 corrective changes
- Correct Kronos core health endpoint to `http://127.0.0.1:8088/health`.
- Add MT5 bridge HTTP health check on `http://127.0.0.1:8090/health`.
- Automatically cancel PENDING approvals when their incident is confirmed RECOVERED.
- Add repair helper for Prometheus/Grafana deployment mistakes.
