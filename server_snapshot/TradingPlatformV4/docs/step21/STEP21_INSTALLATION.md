# Step-by-Step Installation — Abutron Step 21 v1.1

## 0. Preconditions

Before installing Step 21, the server must still have:

- `C:\Abutron\TradingPlatformV4`
- Python venv under `.venv`
- Core and MT5 bridge running
- IC Markets **DEMO** accounts used for certification
- Step 19 full three-bot certification already completed
- Step 20 120-minute certification with `result=PASS`
- no production worker running
- production execution/live/management OFF
- `MT5_DEMO_ONLY=true`

Do not proceed with a live account.

## 1. Copy the bundle to the server

Copy and extract `Abutron-Step21-Controlled-DEMO-Cert-v1.1.zip` to a temporary folder, for example:

```text
C:\Abutron\Step21Bundle
```

## 2. Open Administrator PowerShell

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location "C:\Abutron\Step21Bundle"
```

## 2.1 Verify bridge token is configured (do not print the secret)

```powershell
$TokenLine = Get-Content "C:\Abutron\TradingPlatformV4\.env" |
  Where-Object { $_ -match '^\s*MT5_API_TOKEN\s*=' } |
  Select-Object -First 1

if ($TokenLine) { "MT5_API_TOKEN_PRESENT=YES" } else { "MT5_API_TOKEN_PRESENT=NO" }
```

Expected: `MT5_API_TOKEN_PRESENT=YES`. Do not echo the token itself.

## 3. Install and validate

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File ".\Install-Abutron-Step21-v1.1.ps1"
```

The installer copies the certification runner to:

```text
C:\Abutron\TradingPlatformV4\scripts\Abutron-Step21-Controlled-Demo-Execution-Cert-v1.1.ps1
```

and documentation to:

```text
C:\Abutron\TradingPlatformV4\docs\step21
```

It then performs a safe FLIPPER precheck with no broker order.

## 4. Run full Step 21 PRECHECK

Use the DEMO logins that were used to certify the Scalper and Master equity tiers in Step 19.

```powershell
Set-Location "C:\Abutron\TradingPlatformV4"

$ScalperDemoLogin = [long](Read-Host "Enter SCALPER DEMO login")
$MasterDemoLogin  = [long](Read-Host "Enter MASTER DEMO login")

powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File ".\scripts\Abutron-Step21-Controlled-Demo-Execution-Cert-v1.1.ps1" `
  -Mode PRECHECK `
  -Tier ALL `
  -ScalperLogin $ScalperDemoLogin `
  -MasterLogin $MasterDemoLogin
```

Expected final token:

```text
STEP21=PRECHECK_PASS
```

No DEMO order is authorized in this phase.

## 5. Verify safety before DEMO

Confirm the final PRECHECK output includes:

```text
ABUTRON_EXECUTION_ENABLED=OFF
MT5_LIVE_TRADING=OFF
MT5_MANAGEMENT_ENABLED=OFF
MT5_DEMO_ONLY=True
STEP20_PREREQUISITE=PASS
WORKER_BASELINE=OFF
LIVE_STACK_EXECUTION_LOCK=PASS
LIVE_MONEY_AUTHORIZED=False
```

If any gate fails, stop. Do not add `-AuthorizeDemo`.

## 6. Run Step 21 DEMO certification

Only after PRECHECK passes:

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File ".\scripts\Abutron-Step21-Controlled-Demo-Execution-Cert-v1.1.ps1" `
  -Mode DEMO `
  -Tier ALL `
  -Direction BUY `
  -ScalperLogin $ScalperDemoLogin `
  -MasterLogin $MasterDemoLogin `
  -AuthorizeDemo
```

This invokes controlled DEMO lifecycle certification sequentially for Flipper, Scalper and Master.

## 7. Formal PASS criteria

Require all of the following:

```text
STEP21_FLIPPER_LIFECYCLE=PASS
STEP21_SCALPER_LIFECYCLE=PASS
STEP21_MASTER_LIFECYCLE=PASS
STEP21_FLIPPER_ZERO_RESIDUAL_EXPOSURE=PASS
STEP21_SCALPER_ZERO_RESIDUAL_EXPOSURE=PASS
STEP21_MASTER_ZERO_RESIDUAL_EXPOSURE=PASS
STEP21_ENV_IMMUTABILITY=PASS
STEP21_DEPENDENCY_IMMUTABILITY=PASS
WORKER_FINAL=OFF
PRODUCTION_LIVE_TRADING=OFF
PRODUCTION_MANAGEMENT=OFF
ABUTRON_EXECUTION=OFF
LIVE_MONEY_AUTHORIZED=False
STEP21=PASS
```

## 8. Inspect certification artifact

```powershell
Get-Content "C:\Abutron\TradingPlatformV4\logs\step21_certification.json" -Raw
```

List all Step 21 evidence:

```powershell
Get-ChildItem "C:\Abutron\TradingPlatformV4\logs" `
  -Filter "step21*" `
  -File |
  Sort-Object LastWriteTime -Descending |
  Select-Object Name,Length,LastWriteTime,FullName
```

## 9. After Step 21

Keep production execution OFF. A Step 21 PASS closes the controlled DEMO execution lifecycle gate; it does not authorize live money.
