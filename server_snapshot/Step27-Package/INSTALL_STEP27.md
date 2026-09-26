# Step 27 — Windows installation and certification

## 0. Prerequisites
- Run in **Administrator PowerShell**.
- Step 26A must already have a latest certification report with `"result": "PASS"`.
- Keep all live-money and broker execution switches OFF.
- Place the extracted package at `C:\Abutron\Step27-Package`.

## 1. Pre-install audit

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location C:\Abutron
& "C:\Abutron\Step27-Package\scripts\audit_step27.ps1"
```

Required before continuing:
- `/health` = `status: ok`
- `execution_enabled = false`
- Kronos loaded and database healthy
- MT5 `live_trading = false`
- MT5 `management_enabled = false`
- latest Step26A report = `PASS`

## 2. Install Step27 source and additive tables

```powershell
& "C:\Abutron\Step27-Package\scripts\install_step27.ps1"
```

Required ending:
- `STEP27_GATE_STEP26A=PASS`
- `STEP27_LIVE_SAFETY=PASS`
- `STEP27_PRE_HEALTH=PASS`
- `STEP27_SOURCE_COPY=PASS`
- `STEP27_API_PATCH=PASS`
- `STEP27_COMPILE=PASS`
- `STEP27_DB_TABLES=PASS`
- `STEP27_ROUTES=PASS`
- `STEP27_NO_EXECUTION_REFERENCE=PASS`
- `STEP27_PAYMENT_LICENSE_SEPARATION=PASS`
- `STEP27_INSTALL=PASS`

Record the backup path printed by the installer.

## 3. Keep provider gates disabled initially

Do **not** enable a billing webhook until a real payment provider is selected and its callback format has been mapped.

Recommended initial `.env` state:

```text
STEP27_BILLING_WEBHOOK_ENABLED=false
STEP27_EMAIL_PROVIDER_ENABLED=false
STEP27_PUSH_PROVIDER_ENABLED=false
```

If/when a generic webhook is enabled, set a strong secret server-side only:

```text
STEP27_BILLING_WEBHOOK_SECRET=<strong-random-secret>
```

Never commit or paste that secret into chat/source control.

## 4. Activate the new API safely

```powershell
& "C:\Abutron\Step27-Package\scripts\activate_step27.ps1"
```

Required:
- `STEP27_PORT_8088_RELEASED=PASS`
- `STEP27_LIVE_OPENAPI=PASS`
- `LIVE_MONEY_AUTHORIZED=False`
- `STEP27_ACTIVATE=PASS`

The Windows venv may launch a child process whose executable path displays the base Python interpreter. Certification checks the live API contract rather than assuming parent/child PIDs are identical.

## 5. Manual live smoke check

```powershell
Invoke-RestMethod "http://127.0.0.1:8088/health" | ConvertTo-Json -Depth 10

$OpenApi = Invoke-RestMethod "http://127.0.0.1:8088/openapi.json"
$OpenApi.paths.PSObject.Properties.Name |
    Where-Object { $_ -match "step27|crm|billing|notification" } |
    Sort-Object
```

Open locally:
- `http://127.0.0.1:8088/admin/step27`

The admin console should load, but its data APIs require an admin/superadmin bearer token.

## 6. Certify Step27

```powershell
& "C:\Abutron\Step27-Package\scripts\certify_step27.ps1"
```

Core target:
- `STEP27_GATE_STEP26A=PASS`
- `STEP27_RUNTIME_HEALTH=PASS`
- `STEP27_RUNTIME_SAFETY=PASS`
- `STEP27_LIVE_OPENAPI=PASS`
- `STEP27_AUTH_BOUNDARY=PASS`
- `STEP27_BILLING_WEBHOOK_FAIL_CLOSED=PASS`
- `STEP27_ADMIN_CONSOLE=PASS`
- `STEP27_DB_CONTRACT=PASS`
- `STEP27_EXECUTION_OFF=PASS`
- `STEP27_NO_EXECUTION_REFERENCE=PASS`
- `STEP27_PAYMENT_LICENSE_SEPARATION=PASS`
- `STEP27_CRM=PASS`
- `STEP27_BILLING_CORE=PASS`
- `STEP27_LICENSE_WORKFLOW=PASS`
- `STEP27_NOTIFICATION_OUTBOX=PASS`
- `STEP27_ADMIN_OPERATIONS=PASS`
- `LIVE_MONEY_AUTHORIZED=False`
- `STEP27=PASS`

The report is written under:
`C:\Abutron\TradingPlatformV4\certification\step27\STEP27_CERTIFICATION_<timestamp>.json`

## 7. Provider-specific acceptance gates — later, not faked
Before marking each external integration production-certified:
1. Choose the provider.
2. Install credentials only on the server.
3. Map provider callback fields to Step27 invoice/payment-event fields.
4. Verify HMAC/signature and replay/idempotency behavior.
5. Verify amount and currency matching.
6. Verify payment does not auto-enable live trading.
7. For email/push: send to real test devices/accounts and require provider acknowledgement + device receipt where available.
8. Update the Step27 certification report only after the provider-specific cert passes.

## Rollback

```powershell
& "C:\Abutron\Step27-Package\scripts\rollback_step27.ps1" `
  -BackupDir "C:\Abutron\Backups\PreStep27\<timestamp>"
```

Then reactivate/restart the API. Step27 database tables are retained intentionally for audit/history; rollback restores/removes source files and the API router only.
