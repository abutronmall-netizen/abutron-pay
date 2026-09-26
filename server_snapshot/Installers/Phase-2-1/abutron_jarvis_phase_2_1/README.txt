ABUTRON JARVIS — PHASE 2.1 UNIFIED PRODUCTION HEALTH COLLECTOR

Purpose
-------
Read-only, deterministic production health collection for Jarvis.
No trading, restart, deployment, config mutation, or arbitrary shell execution is added.

New authenticated endpoint
--------------------------
GET /v1/system/health
Header: X-Jarvis-Token: <existing JARVIS_API_TOKEN>

Collectors
----------
- Kronos:        http://127.0.0.1:8088/health
- MT5 bridge:    http://127.0.0.1:8090/health
- MT5 process:   terminal64.exe
- Hermes:        existing hardened Jarvis->Hermes client
- Jarvis SQLite: read-only PRAGMA quick_check
- Redis:         disabled unless JARVIS_HEALTH_REDIS_ENABLED=true
- Prometheus:    http://127.0.0.1:9090/-/ready
- Grafana:       http://127.0.0.1:3000/api/health (optional by default)
- Windows Exporter: http://127.0.0.1:9182/metrics
- Host CPU/RAM/disk

Security invariants
-------------------
- All HTTP collector URLs must resolve to explicit loopback hostnames in config.
- No user-supplied target URLs.
- No shell commands.
- No process kills/restarts.
- No file writes by collectors.
- SQLite uses read-only mode.
- Redis only sends PING when explicitly enabled.
- Endpoint requires the existing Jarvis token.
- OBSERVE_ONLY is reported and expected.

Install (build/test only)
-------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_phase_2_1.ps1

Install + restart Jarvis only
-----------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_phase_2_1.ps1 -Activate

Verify runtime
--------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify_phase_2_1.ps1

Optional environment overrides
------------------------------
JARVIS_HEALTH_KRONOS_BASE_URL=http://127.0.0.1:8088
JARVIS_HEALTH_KRONOS_PATH=/health
JARVIS_HEALTH_MT5_BRIDGE_BASE_URL=http://127.0.0.1:8090
JARVIS_HEALTH_MT5_BRIDGE_PATH=/health
JARVIS_HEALTH_MT5_PROCESS=terminal64.exe
JARVIS_HEALTH_DB_PATH=C:\Abutron\Jarvis\data\jarvis.db
JARVIS_HEALTH_REDIS_ENABLED=false
JARVIS_HEALTH_HTTP_TIMEOUT=3
JARVIS_HEALTH_TOTAL_TIMEOUT=8
JARVIS_HEALTH_CPU_WARN=90
JARVIS_HEALTH_MEMORY_WARN=90
JARVIS_HEALTH_DISK_WARN=90

Note
----
A degraded response does not automatically mean the build failed. It means at least
one required monitored component is not healthy. The snapshot identifies the exact
component and error without exposing credentials.
