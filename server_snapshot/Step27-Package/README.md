# Abutron Step 27 — CRM + Billing/Licensing + Notifications + Customer Operations

Version: **1.0.0**

## Scope
- 27A CRM: customer profile, notes, follow-up tasks.
- 27B Billing/Licensing: invoices, idempotent payment events, explicit license-grant approval.
- 27C Notifications: customer preferences, durable outbox, in-app dispatch, fail-closed external email/push gates.
- 27D Customer Operations: customer status APIs, admin operations console, summary/certification.

## Non-negotiable safety
- No Step27 module imports MT5/cTrader execution gateways.
- A payment event does **not** activate a license automatically.
- License approval does **not** change trading execution or authorize live money.
- `ABUTRON_EXECUTION_ENABLED`, `MT5_LIVE_TRADING`, `MT5_MANAGEMENT_ENABLED`, and live-money authorization remain outside Step27.
- Generic billing webhook is disabled by default and requires HMAC verification when enabled.
- Email and push providers are fail-closed until a provider adapter is installed and certified.

## Production truth
Step27 v1.0.0 certifies the internal CRM/billing/license/outbox/admin platform contract. It does **not** certify a real external payment processor, email provider, push provider, signed mobile store build, or broker live execution.

See `INSTALL_STEP27.md`.
