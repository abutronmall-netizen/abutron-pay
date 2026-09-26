# ABUTRON STEP 21B — IC Markets cTrader OAuth + Account Discovery v1.1.2

Repair release for the Windows VPS Core-import failure found in v1.1.0.

## Truth
The v1.1.0 gateway package passed all 16 gateway tests on the VPS, then failed only because the installer executed `from abutron.api import app` while PowerShell was still in `C:\Abutron\Step21B`. Python therefore could not resolve the existing `abutron` source package.

v1.1.2 fixes only the installation/orchestration layer. OAuth, account discovery, IC Markets filtering, USD equity routing, and all broker safety behavior are unchanged.

## Repair behavior
- preserves the existing cTrader `.env` and SQLite bindings;
- reuses `.venv_ctrader`;
- validates the gateway before touching Core;
- installs the Core adapter/routes idempotently;
- runs Core syntax/import validation from `C:\Abutron\TradingPlatformV4`;
- checks that `TradingService` still uses `MT5Gateway` (Step 21B does not switch execution);
- automatically restores the pre-v1.1.2 Core files/env on failure;
- sends zero broker orders.

## Safety
`CTRADER_ENABLE_LIVE_CONNECTION=false`
`CTRADER_DEMO_EXECUTION_ENABLED=false`
`CTRADER_LIVE_MONEY_AUTHORIZED=false`
`CTRADER_KILL_SWITCH=true`

## Install
Run `scripts\install_step21b.ps1`, then `scripts\step21b_precredential.ps1`.
Do not run the credential certification until Spotware client credentials exist.


## v1.1.2 repair
Fixes Windows route-verification false failure by emitting one FastAPI route per stdout line. No OAuth, discovery, risk, router, or execution behavior changed.
