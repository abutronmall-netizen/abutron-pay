# Abutron Step 26A — Customer / Admin / Mobile v1.0.1

## Scope
Step 26A turns the existing TradingPlatformV4 customer foundation into a coherent customer-facing product layer.

Included:
- mobile bootstrap/status/profile/account/trade API;
- device registration/revocation;
- notification read-state;
- customer support tickets;
- richer admin customer/support APIs;
- `/admin/step26a` operator console;
- React Native / Expo Android+iOS source;
- installer, certification and rollback tooling.

## Safety boundary
Step 26A is **READ_ONLY for trading**.
It contains no order-entry endpoint, broker execution control, or MT5/cTrader order call.

## Explicitly deferred
- real cTrader broker lifecycle: Step 24;
- broker failure/recovery certification: Step 25;
- push provider delivery (FCM/APNs): Step 27;
- production payment adapters/reconciliation: Step 27;
- signed app-store builds and device acceptance: Step 26B / release certification.

## Install
Use `scripts/install_step26a.ps1` on the certified TradingPlatformV4 server.
Restart the platform.
Then run `scripts/certify_step26a.ps1`.

## v1.0.1 repair
- Handles UTF-8 BOM in the existing `abutron/api.py`.
- API patching is idempotent and safe to rerun after a partial v1.0.0 install.
- `audit_step26a.ps1` restores the caller's working directory.
- `repair_step26a.ps1` reruns the normal installer through the corrected path.
