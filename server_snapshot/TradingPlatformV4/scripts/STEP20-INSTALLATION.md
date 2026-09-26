# Abutron Step 20 — Soak / Endurance Certification V1

Build marker: `STEP20_SOAK_ENDURANCE_CERT_V1`

## Purpose
Step 20 proves that the already-certified trading stack remains stable over a sustained period while the real production worker performs live read/decision cycles under hard execution locks. It does **not** authorize live-money trading.

## Certification acceptance
A production PASS requires at least **120 minutes** and all of the following:

- Step 19 evidence ledger remains valid for Flipper, Scalper and Master (3/3).
- `ABUTRON_EXECUTION_ENABLED=false`, `MT5_LIVE_TRADING=false`, `MT5_MANAGEMENT_ENABLED=false`, `MT5_DEMO_ONLY=true`.
- MT5 is connected to the canonical production-pinned DEMO account from `.env`; exact login is verified but not printed.
- Core, MT5 Bridge, Jarvis, Prometheus, Grafana, Windows exporter, PostgreSQL and Redis/Memurai remain available.
- Kronos remains loaded; Jarvis remains `OBSERVE_ONLY`.
- Core/Bridge/Jarvis/MT5 PIDs remain stable during steady-state soak.
- Real `abutron.worker` generates repeated decisions; every observed execution result remains `None`.
- No worker traceback; no decision stall longer than the configured threshold.
- The worker sustains its live account/position/data decision path, while independent read-only bars/context probes succeed across M1/M5/M15/H1/H4.
- Resource growth remains below the fail-closed leak thresholds.
- Local read-only HTTP p95 latency remains <= 5000 ms.
- No Abutron-owned position, pending order or deal is created during the run.
- Production `.env` and critical trading source files are unchanged.
- Worker is stopped at the end.

Step 13 already certified controlled MT5 outage/fail-closed/recovery. Step 20 focuses on sustained steady-state endurance rather than deliberately repeating that outage.

## Files

- `step20_soak_probe_v1.py` — Step 19 evidence, DB, Redis and MT5 read-only integrity probe. SHA256 `F4612987C17CCBE4208748D0828A78C116C694E2D402D24ACF0235B62F5ED470`
- `Abutron-Step20-Soak-Endurance-Cert-v1.ps1` — 120-minute soak runner. SHA256 `751B06A21A2E34BA534CADB3EBD1C1E1119A05C0C4A8B98AEDB435A0ED05D353`
- `Abutron-Step20-Install-Validate-Preflight-v1.ps1` — installation/preflight validator. SHA256 `CE1C194DEAAE557A288C5D472374C57C9727FD13F4DED44F7F73A955439E8239`

## Install location
Copy all three scripts to:

`C:\Abutron\TradingPlatformV4\scripts`

## Required account state before preflight
Step 19 temporarily certified multiple DEMO accounts using process-local login overrides. Step 20 intentionally returns to the **canonical production configuration**, so MT5 must be logged into the DEMO account whose login is already pinned by `MT5_EXPECTED_LOGIN` in the production `.env`. Do not edit `.env` to make Step 20 pass.

## Preflight
Run as Administrator:

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File "C:\Abutron\TradingPlatformV4\scripts\Abutron-Step20-Install-Validate-Preflight-v1.ps1"
```

A valid preflight ends with `STEP20_INSTALL_PRECHECK=PASS`. No broker order is sent.

## Optional short diagnostic
This is useful only to catch immediate faults. It is **not** Step 20 certification:

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File "C:\Abutron\TradingPlatformV4\scripts\Abutron-Step20-Install-Validate-Preflight-v1.ps1" `
  -RunDiagnostic15Min
```

A short run ends as `STEP20=DIAGNOSTIC_PASS`, never `STEP20=PASS`.

## Full Step 20 certification
Run as Administrator and leave the session running for at least two hours:

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File "C:\Abutron\TradingPlatformV4\scripts\Abutron-Step20-Soak-Endurance-Cert-v1.ps1" `
  -DurationMinutes 120 `
  -SampleSeconds 15
```

Do not start another worker or switch MT5 accounts while this runs.

## Evidence generated on the VPS

- `C:\Abutron\TradingPlatformV4\logs\step20_soak_<timestamp>_metrics.csv`
- `C:\Abutron\TradingPlatformV4\logs\step20_worker_<timestamp>_stdout.log`
- `C:\Abutron\TradingPlatformV4\logs\step20_worker_<timestamp>_stderr.log`
- `C:\Abutron\TradingPlatformV4\logs\step20_summary_<timestamp>.json`
- On full PASS only: `C:\Abutron\TradingPlatformV4\logs\step20_certification.json`

## Final PASS signature
A successful production certification includes:

```text
STEP20_DURATION=PASS
STEP20_DECISION_ACTIVITY=PASS
STEP20_ALL_ACTIVITY_DRY_RUN=PASS
STEP20_TRACEBACKS=0
STEP20_INFRASTRUCTURE=PASS
STEP20_RESOURCE_STABILITY=PASS
STEP20_SOURCE_IMMUTABILITY=PASS
STEP20_ENV_IMMUTABILITY=PASS
STEP20_ZERO_UNINTENDED_ORDERS=PASS
STEP20_CORE_CONTINUITY=PASS
STEP20_BRIDGE_CONTINUITY=PASS
STEP20_JARVIS_CONTINUITY=PASS
WORKER_FINAL=OFF
PRODUCTION_LIVE_TRADING=OFF
PRODUCTION_MANAGEMENT=OFF
ABUTRON_EXECUTION=OFF
LIVE_MONEY_AUTHORIZED=False
STEP20=PASS
```
