# Step 21A — Windows installation (IC Markets cTrader Cloud Gateway)

## 0. Safety state
Do not turn on DEMO execution or live money during installation. The required initial state is:

```text
CTRADER_ENABLE_LIVE_CONNECTION=false
CTRADER_DEMO_EXECUTION_ENABLED=false
CTRADER_LIVE_MONEY_AUTHORIZED=false
CTRADER_KILL_SWITCH=true
```

## 1. Extract the release
Extract this package to:

```text
C:\Abutron\Step21A
```

## 2. Install in its own Python environment
Open **Administrator PowerShell**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location 'C:\Abutron\Step21A'
.\scripts\install_windows.ps1
```

Target output:

```text
STEP21A_INSTALL=PASS
CTRADER_DEDICATED_VENV=PASS
KRONOS_VENV_UNCHANGED=TRUE
CTRADER_DEMO_EXECUTION_ENABLED=false
CTRADER_LIVE_MONEY_AUTHORIZED=false
CTRADER_KILL_SWITCH=true
NEXT=RUN_PREAPPROVAL_CHECK
```

## 3. Pre-approval certification

```powershell
Set-Location 'C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway'
.\scripts\preapproval_check.ps1
```

Target includes `STEP21A_PREAPPROVAL=PASS` and `BROKER_ORDER_SENT=False`.

## 4. Register the cTrader application
Use `docs\CTRADER_APP_REGISTRATION.md`. Spotware must approve the app before production OAuth credentials are available.

## 5. After approval: configure credentials
Edit only:

```text
C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway\.env
```

Set:

```text
CTRADER_CLIENT_ID=<Spotware client id>
CTRADER_CLIENT_SECRET=<Spotware client secret>
```

Do **not** change the four safety lines from Step 0.

## 6. Read-only credential readiness

```powershell
Set-Location 'C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway'
.\scripts\readiness_after_credentials.ps1
```

Expected: gateway health plus `STEP21A_CREDENTIAL_READINESS=PASS`, `BROKER_ORDER_SENT=False`.

## 7. Public HTTPS callback
Configure the reverse proxy so **only** the browser-facing OAuth start/callback routes are public. The gateway remains bound to `127.0.0.1:8091`; account, token, reconcile and order endpoints stay localhost-only behind Abutron Core. Use `deployment\caddy\Caddyfile.snippet`. Do not expose port 8091 to the Internet.

## 8. Core integration
The installer copies these additive adapters:

```text
C:\Abutron\TradingPlatformV4\abutron\gateways\ctrader_cloud.py
C:\Abutron\TradingPlatformV4\abutron\gateways\ctrader_volume.py
```

Step 21A does **not** automatically replace `TradingService.gateway=MT5Gateway()`. That switch belongs to Step 21B after OAuth/account/symbol mapping is verified.

## 9. Step 21B gate
Next certification is read-only:
- OAuth callback PASS
- IC Markets cTrader DEMO account discovered
- ctidTraderAccountId persisted
- trader/account data PASS
- XAUUSD symbol resolved
- min/step/max/lotSize captured
- reconcile PASS
- token refresh PASS
- still zero broker orders

Only after Step 21B passes do we enable a single controlled DEMO lifecycle in Step 21C.
