# Step 21A v1.0.0 → v1.0.1 Repair

The v1.0.0 Windows installer created the dedicated cTrader virtual environment successfully, but omitted `.env.example` and `core_integration` from the installed self-test tree. That caused three `FileNotFoundError` test failures.

v1.0.1 repairs the installed tree in place and preserves the existing `C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway\.env` if it already exists.

## Safe repair

1. Do **not** delete the existing installed `.env`.
2. Extract v1.0.1 to a fresh source folder such as `C:\Abutron\Step21A-v101`.
3. Open Administrator PowerShell.
4. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location 'C:\Abutron\Step21A-v101'
.\scripts\install_windows.ps1
```

Expected final markers:

```text
11 passed
STEP21A_INSTALL=PASS
STEP21A_REPAIR_FROM_V1_0_0=PASS
CTRADER_TARGET_TREE=PASS
CTRADER_DEDICATED_VENV=PASS
KRONOS_VENV_UNCHANGED=TRUE
CTRADER_DEMO_EXECUTION_ENABLED=false
CTRADER_LIVE_MONEY_AUTHORIZED=false
CTRADER_KILL_SWITCH=true
BROKER_ORDER_SENT=False
NEXT=RUN_PREAPPROVAL_CHECK
```

Then run:

```powershell
Set-Location 'C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway'
.\scripts\preapproval_check.ps1
```

Expected:

```text
11 passed
STEP21A_PREAPPROVAL=PASS
LIVE_CONNECTION_ENABLED=False
DEMO_EXECUTION_ENABLED=False
LIVE_MONEY_AUTHORIZED=False
KILL_SWITCH=True
BROKER_ORDER_SENT=False
```

Do **not** run `readiness_after_credentials.ps1` until real Spotware/cTrader Open API client credentials have been entered into `.env`.
