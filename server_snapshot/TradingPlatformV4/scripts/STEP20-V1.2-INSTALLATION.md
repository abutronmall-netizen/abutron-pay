# ABUTRON STEP 20 V1.2 — Soak / Endurance Certification

Build marker: `STEP20_SOAK_ENDURANCE_CERT_V1_2`

## Purpose of V1.2
V1.2 fixes the preflight working-directory/config-resolution defect found in V1.1. The helper and runner explicitly normalize their working directory to `C:\Abutron\TradingPlatformV4` before importing production settings. The database probe now fails closed unless the production platform database backend resolves to PostgreSQL, then performs `SELECT 1` through the production `abutron.platform_db` session wiring.

## Safety
- Production `.env` is never edited.
- `ABUTRON_EXECUTION_ENABLED=false`.
- `MT5_LIVE_TRADING=false`.
- `MT5_MANAGEMENT_ENABLED=false`.
- `MT5_DEMO_ONLY=true`.
- Preflight places no order and does not start the worker.
- The diagnostic/certification runner starts the production worker only in an isolated child process with execution/live trading/management forced OFF.
- Live-money trading is never authorized.

## Sequence
1. Keep the production worker OFF.
2. Connect MT5 to the canonical production-pinned IC Markets DEMO account already configured in `.env`.
3. Install this bundle and run the V1.2 preflight only.
4. If and only if preflight passes, run a 15-minute diagnostic soak.
5. Review diagnostic evidence.
6. If diagnostic passes, run the 120-minute certification soak.

## Expected V1.2 preflight evidence
- `STEP20_WORKING_DIRECTORY_ROOT=PASS`
- `STEP20_PRODUCTION_SAFETY=PASS`
- all three Step19 prerequisite rows PASS
- `STEP20_PLATFORM_DB_BACKEND=postgresql`
- `STEP20_DATABASE_CONNECTIVITY=PASS`
- `STEP20_REDIS_CONNECTIVITY=PASS`
- canonical MT5 DEMO identity checks PASS
- zero positions / zero pending orders
- `STEP20_HELPER_PREFLIGHT=PASS`
- `STEP20_V1_2_INSTALL_PRECHECK=PASS`
- `WORKER=OFF`
- `DEMO_ORDER_SENT=False`
- `LIVE_MONEY_AUTHORIZED=False`

## Component SHA256
- helper: `F03ACFE2D8529441584B3E68CBF3BC785C3F223182221C8A50289923416748CB`
- runner: `721AAB0F7E08EE873708CD7823CA6662F668BAC348B331EBC068A76EEE702C80`
- installer: `69D1DC1E27BCFD073A00E02BA2A42F0497EB068218E212BD7BFFB1D4408D50EE`
