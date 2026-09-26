# Step 21D v1.3.0 — Windows Installation

## Purpose
Failure/recovery hardening on top of the Step 21C VPS-passed build. This stage is safe to install before Spotware credentials arrive.

## Install
Extract this release to `C:\Abutron\Step21D` and run Administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location "C:\Abutron\Step21D"
.\scripts\install_step21d.ps1
```

Expected key output:

```text
47 passed
STEP21D_INSTALL=PASS
READ_ONLY_TRANSPORT_RETRY=PASS
MUTATION_AUTO_RETRY=FALSE
UNCERTAIN_RECOVERY_INSPECTION=PASS
ORDER_HISTORY_CLIENT_ORDER_ID_MATCH=PASS
TOKEN_REFRESH_ROTATION=PASS
WORKER_RESTART_PATH=PASS
LIVE_MONEY_AUTHORIZED=False
BROKER_ORDER_SENT=False
NEXT=RUN_STEP21D_PRECHECK
```

Then:

```powershell
Set-Location "C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway"
.\scripts\step21d_precheck.ps1
```

Expected:

```text
47 passed
STEP21D_BUILD_PRECERT=PASS
READ_ONLY_TRANSPORT_RETRY=PASS
MUTATION_AUTO_RETRY=FALSE
UNCERTAIN_RECOVERY_INSPECTION=PASS
TOKEN_REFRESH_ROTATION=PASS
WORKER_RESTART_PATH=PASS
LIVE_MONEY_AUTHORIZED=False
BROKER_ORDER_SENT=False
STEP21D_REAL_NETWORK_CERT_REQUIRES_OAUTH=TRUE
```

## Later: real OAuth recovery certification
Do not run until Step 21B real OAuth/account binding is PASS and the gateway is running:

```powershell
.\scripts\step21d_certify.ps1 -UserId <AbutronUserId> -AccountId <ctidTraderAccountId>
```

This real-network certificate performs a DEMO worker restart, OAuth token rotation, and read-only UNCERTAIN recovery inspection. It sends no broker order.
