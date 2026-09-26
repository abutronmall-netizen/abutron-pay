# ABUTRON TRADING PLATFORM v4.0

**Kronos + Fusion + Institutional + Risk + Capital + Equity Router + Flipper + Scalper + Master + MT5 + Database + Admin + Mobile**

v4.0 is the consolidation baseline for the complete Abutron platform. It is built from the v3.10 Kronos Fusion production-oriented package and adds the missing product-routing, lifecycle, customer-platform and deployment layers needed to drive the canonical architecture end to end.

## Canonical path

```text
LIVE MARKET DATA → KRONOS → INSTITUTIONAL + TECHNICAL + REGIME → FUSION → CONFIDENCE → THESIS
→ BUY/SELL/HOLD → RISK → CAPITAL → EQUITY ROUTER → FLIPPER/SCALPER/MASTER
→ MT5 → BROKER → EXECUTED → MANAGED → CLOSED → DATABASE → ADMIN → MOBILE
```

## Implemented in this v4.0 baseline

- official Kronos runtime adapter and model download hooks;
- institutional, technical and regime feature engines;
- Fusion, confidence and thesis engine;
- risk engine with licensing, stale data, spread, daily loss, open-risk and emergency drawdown guards;
- capital engine that never forces broker minimum lot above the authorized risk budget;
- sticky equity router preventing mid-position tier changes;
- independent Flipper, Scalper and Master strategy-policy engines;
- Windows-native MT5 gateway with live/dry-run split, idempotency, opposite-position protection, order check, positions, history, close and management endpoints;
- trade worker with execution persistence and MT5 history synchronization;
- SQLAlchemy platform database with users, trading accounts, licenses, subscriptions, trade records, notifications and audit events;
- Argon2 password hashing, signed JWT sessions and admin RBAC;
- registration requiring Terms + trading-risk acceptance;
- admin web dashboard;
- React Native / Expo mobile source foundation;
- PostgreSQL + Redis infrastructure compose file;
- Windows install/start/stop/certification scripts;
- explicit 100% production acceptance gates.

## Safety defaults

```text
ABUTRON_EXECUTION_ENABLED=false
MT5_LIVE_TRADING=false
MT5_MANAGEMENT_ENABLED=false
```

These are independent switches by design.

## Fresh Windows install

See `docs/WINDOWS_FRESH_INSTALL.md`.

Quick path:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install_windows.ps1 -UsePostgres
.\scripts\start_platform.ps1
.\scripts\certify_live.ps1
```

Admin: `http://127.0.0.1:8088/admin`

## 100% status

The source package can be code-complete while external gates remain. Broker execution, a live MT5 host, production Kronos model installation, TLS/domain, payment-provider credentials, push credentials, signed Android/iOS builds and low-risk live certification require the actual deployment environment. `docs/100_PERCENT_ACCEPTANCE_GATES.md` is authoritative for final release status.
