# ABUTRON STEP 23 — cTrader OAuth Production Preparation v1.0.0

Purpose: prepare the existing Abutron cTrader gateway for real cTrader OAuth while the Open API application is still in `Submitted` status.

## Important
- Do **not** use the client secret that was exposed in chat. Rotate/regenerate it first.
- Never paste the replacement secret into chat.
- This package does not enable demo order execution or live-money execution.
- It preserves the kill switch and both execution flags as OFF.

## Existing production callback
`https://api.abutronfx.online/v1/ctrader/oauth/callback`

The existing Step 22 Caddy configuration already forwards `/v1/ctrader/oauth/start*` and `/v1/ctrader/oauth/callback*` to the local cTrader gateway on port 8091.

## Run order
1. Rotate the exposed cTrader client secret in the Open API portal.
2. Copy this folder to the VPS, e.g. `C:\Abutron\Step23`.
3. Run `scripts\step23_preapproval_validate.ps1`.
4. After the application becomes **Approved**, run `scripts\configure_ctrader_credentials.ps1`.
5. Run `scripts\step23_postapproval_readiness.ps1`.
6. Then begin the real OAuth authorization and demo-account discovery.

Live-money status remains OFF throughout this package.
