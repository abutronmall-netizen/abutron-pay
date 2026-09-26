# RC1-09 — Step-by-step Windows installation and certification

## Scope
RC1-09 is notification-only. It reads RC1-08 incidents/approvals and sends Telegram and WhatsApp/Meta alerts. It cannot execute trades, approve actions, restart services, or accept inbound chat commands.

## Prerequisites
- Run PowerShell as Administrator.
- RC1-08 must already be certified and healthy on `127.0.0.1:8788`.
- Jarvis must remain `OBSERVE_ONLY`.
- Kronos production execution must remain disabled.
- Place `Abutron_RC1-09_Telegram_WhatsApp_Alerts_v1.0.0.zip` in `C:\Abutron\Packages`.

## A. Install the RC1-09 service

```powershell
cd C:\Abutron\Packages

Expand-Archive `
  .\Abutron_RC1-09_Telegram_WhatsApp_Alerts_v1.0.0.zip `
  . `
  -Force

cd C:\Abutron\Packages\Abutron_RC1-09_Telegram_WhatsApp_Alerts_v1.0.0

Set-ExecutionPolicy `
  -Scope Process `
  -ExecutionPolicy Bypass `
  -Force

.\scripts\Install-RC1-09-v1.0.0.ps1
```

Expected:
- `PASS RC1-08 healthy / OBSERVE_ONLY`
- deterministic tests pass
- Python compile passes
- `PASS RC1-09 service Running / NOTIFY_ONLY`
- `RC1_09_INSTALLED=True`

Verify:

```powershell
Get-ScheduledTask -TaskName "Abutron-Jarvis-RC1-09" |
Select-Object TaskName,State

Invoke-RestMethod http://127.0.0.1:8789/health |
ConvertTo-Json -Depth 10
```

Required safety fields:
- `mode = NOTIFY_ONLY`
- `actions_enabled = false`
- `rc1_08_ok = true`

At this stage both transports may still be disabled. That is expected.

---

## B. Telegram setup

### B1. Create the bot
In Telegram, open the official **@BotFather** account.

1. Send `/newbot`.
2. Choose the Abutron alert bot name.
3. Copy the bot token.
4. Do not paste that token into chat, email, GitHub, or screenshots.

### B2. Store the token
From the package directory:

```powershell
.\scripts\Configure-Telegram.ps1
```

Paste the BotFather token into the secure prompt.

### B3. Discover the correct numeric chat ID
From your own Telegram account, open the new bot and send:

```text
/start
```

Then:

```powershell
.\scripts\Discover-Telegram-ChatId.ps1
```

The script prints candidate `ChatId` values.

Use the **numeric ChatId** only. Do not use `@abutronfx` or another username.

Configure it:

```powershell
.\scripts\Configure-Telegram.ps1 -ChatId YOUR_NUMERIC_CHAT_ID
```

### B4. Telegram live test

```powershell
.\scripts\Test-RC1-09-Transports.ps1 -Telegram
```

Expected:

```text
PASS Telegram send + delivery audit
```

Confirm the certification message appears in Telegram.

---

## C. WhatsApp / Meta preparation

RC1-09 defaults to **WhatsApp template mode** for production alert reliability.

You need:
- Meta App with WhatsApp product
- WhatsApp Business Account / WABA
- registered business phone number
- Phone Number ID
- current Graph API version shown in your Meta app
- system-user access token with WhatsApp messaging permission
- Meta App Secret
- webhook verify token that you choose
- approved utility message template

Do not put any of these secrets in source control.

### C1. Create the message template

In WhatsApp Manager create a utility template:

Template name:

```text
abutron_system_alert
```

Language:

```text
en_US
```

Suggested body:

```text
ABUTRON JARVIS ALERT
Severity: {{1}}
{{2}}
{{3}}
Reference: {{4}}
```

RC1-09 fills:
1. severity
2. title
3. incident/recovery/approval summary
4. incident or approval reference

Wait until Meta shows the template as approved before the production transport test.

---

## D. Configure WhatsApp credentials

Use the exact Graph API version currently shown/supported by your Meta app. Do not guess it.

Example command shape:

```powershell
.\scripts\Configure-WhatsApp.ps1 `
  -PhoneNumberId "YOUR_PHONE_NUMBER_ID" `
  -Recipient "27XXXXXXXXX" `
  -GraphVersion "vXX.X" `
  -TemplateName "abutron_system_alert" `
  -TemplateLanguage "en_US"
```

The script will securely prompt for:
- Meta access token
- Meta App Secret
- webhook verify token

Secrets are stored only in:

```text
C:\Abutron\Jarvis\rc1_09\.env
```

The installer restricts that file to Administrators and SYSTEM.

Verify:

```powershell
Invoke-RestMethod http://127.0.0.1:8789/health |
ConvertTo-Json -Depth 10
```

Required:

```text
channels.telegram = true
channels.whatsapp = true
mode = NOTIFY_ONLY
actions_enabled = false
```

---

## E. Publish only the WhatsApp delivery webhook

Run:

```powershell
.\scripts\Patch-Caddy-WhatsApp-Webhook.ps1
```

The script:
- backs up the existing Caddyfile
- builds and validates a candidate config
- exposes only GET/POST on the exact RC1-09 webhook path
- reloads Caddy
- verifies trading/admin/docs paths remain externally blocked
- rolls back if application or validation fails

Expected callback:

```text
https://api.abutronfx.online/v1/notifications/whatsapp/webhook
```

The public route does **not** expose the RC1-09 health, metrics, deliveries, trading controls, or any approval endpoint.

---

## F. Configure the Meta webhook

In the Meta App dashboard / WhatsApp webhook configuration:

Callback URL:

```text
https://api.abutronfx.online/v1/notifications/whatsapp/webhook
```

Verify token:
- use the same value entered into `Configure-WhatsApp.ps1`

Subscribe the app/WABA to message status events.

Security behavior:
- GET verification requires the exact verify token.
- POST webhook payloads require a valid `X-Hub-Signature-256` generated with the Meta App Secret.
- invalid signatures receive HTTP 401.
- incoming WhatsApp chat messages are ignored.
- only outbound message delivery statuses are consumed.

---

## G. WhatsApp transport test

```powershell
.\scripts\Test-RC1-09-Transports.ps1 -WhatsApp
```

Expected:

```text
PASS WhatsApp API accepted message
```

Confirm the message arrives on the configured WhatsApp recipient.

After the Meta webhook is live, RC1-09 records status progression such as:
- sent
- delivered
- read
- failed

Inspect the audit without printing credentials:

```powershell
$tokenLine = Get-Content "C:\Abutron\Jarvis\.env" |
  Where-Object { $_ -match '^JARVIS_API_TOKEN=' } |
  Select-Object -First 1

$token = $tokenLine.Substring(17).Trim()

Invoke-RestMethod `
  http://127.0.0.1:8789/deliveries `
  -Headers @{Authorization="Bearer $token"} |
ConvertTo-Json -Depth 10
```

---

## H. Combined pre-reboot test

```powershell
.\scripts\Test-RC1-09-Transports.ps1 -Telegram -WhatsApp
```

Then:

```powershell
Invoke-RestMethod http://127.0.0.1:8789/metrics
```

Check that there are no unexpected DEAD deliveries.

RC1-08 must still be healthy:

```powershell
Invoke-RestMethod http://127.0.0.1:8788/health |
Format-List
```

Required:
- `status = ok`
- `mode = OBSERVE_ONLY`

Kronos safety:

```powershell
Invoke-RestMethod http://127.0.0.1:8088/health |
ConvertTo-Json -Depth 10
```

Required:
- `execution_enabled = false`
- `mt5.live_trading = false`

---

## I. Final reboot certification

Perform a real Windows reboot:

```powershell
Restart-Computer
```

After reconnecting, open PowerShell as Administrator:

```powershell
cd C:\Abutron\Packages\Abutron_RC1-09_Telegram_WhatsApp_Alerts_v1.0.0

Set-ExecutionPolicy `
  -Scope Process `
  -ExecutionPolicy Bypass `
  -Force

.\scripts\Certify-RC1-09-PostReboot.ps1
```

The certifier requires both Telegram and WhatsApp by default.

Expected finish:

```text
RC1_09_CERTIFIED=True
RC1-09 — Telegram + WhatsApp / Meta Alerts CERTIFIED
NEXT=RC1-10 Security / Release Audit
```

A certification JSON is written under:

```text
C:\Abutron\Jarvis\certification\rc1_09
```

---

## J. Operational behavior after certification

RC1-09 alerts only:
- new HIGH/CRITICAL incident OPEN
- matching incident RECOVERED transition
- new PENDING human approval request

It does not alert on historical recovered incidents during first startup.

It does alert on a currently OPEN HIGH/CRITICAL incident when first observed, because an active incident must not be silently ignored.

Each event/channel pair is unique in SQLite, preventing duplicate sends after restart.

Transport failures before provider acceptance use bounded retry/backoff.

After WhatsApp returns a message ID, RC1-09 relies on signed Meta delivery-status webhooks rather than blindly resending an uncertain accepted message.

---

## K. Rollback boundary

RC1-09 is isolated from RC1-08.

If the RC1-09 notification service has a problem:

```powershell
Stop-ScheduledTask -TaskName "Abutron-Jarvis-RC1-09"
```

RC1-08, Jarvis, Kronos, MT5, Prometheus, and Grafana continue independently.

Do not delete the RC1-09 SQLite database during troubleshooting because it is the delivery/deduplication audit trail.

No RC1-09 rollback should enable trading or modify RC1-08.
