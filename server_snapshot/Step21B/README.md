# ABUTRON STEP 21B — IC Markets cTrader OAuth + Account Discovery v1.1.0

Zero-order certification layer built on Step 21A v1.0.1.

## Purpose
- customer-authenticated **Connect IC Markets** routes in Abutron Core;
- cTrader OAuth token/account binding;
- IC Markets/Raw Trading account filtering;
- DEMO-only account discovery;
- deposit-currency resolution;
- moneyDigits-correct balance + broker-calculated unrealized P&L => equity;
- XAUUSD symbol ID and min/step/max volume discovery;
- fail-closed equity routing when deposit currency is not USD;
- **zero broker orders**.

## Safety
`CTRADER_ENABLE_LIVE_CONNECTION=false`
`CTRADER_DEMO_EXECUTION_ENABLED=false`
`CTRADER_LIVE_MONEY_AUTHORIZED=false`
`CTRADER_KILL_SWITCH=true`

## Install
Run `scripts\install_step21b.ps1`, then `scripts\step21b_precredential.ps1`.
After Spotware credentials are approved/configured, start the gateway, complete OAuth, and run `scripts\step21b_certify.ps1 -UserId <AbutronUserId>`.
