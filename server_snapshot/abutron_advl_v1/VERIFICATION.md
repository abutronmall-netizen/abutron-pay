# Abutron ADVL Integration v1.0 — Verification

Release target: Abutron server-side core at `C:\Abutron\TradingPlatformV4`.

## Verified safeguards

- ADVL is SHADOW by default and cannot change a trade.
- KRONOS-only mode is never modified by ADVL.
- LIVE contribution is restricted to FUSION / INSTITUTIONAL modes.
- Default live weight is 5%; code hard-caps it at 10%.
- Minimum quality and minimum absolute-signal gates are enforced.
- Missing, stale, future, out-of-order, malformed, and negative-volume data fails neutral.
- Different provider/universe identities reset the cumulative state instead of mixing series.
- Duplicate timestamps do not double-count the cumulative line.
- Millisecond epoch timestamps are normalized to seconds.
- State writes are atomic; a sidecar exception fails neutral rather than crashing the trading core.
- The patcher AST-parses `fusion.py` before and after modification.
- The installer keeps an independent rollback copy and restores original production files after a compile/test failure.
- Re-running the patcher does not duplicate the injected Fusion logic.

## Test results

Standalone ADVL unit suite: **15/15 PASS**.

Synthetic production-layout checks:

- `fusion.py` patch + Python compile: **PASS**
- patch idempotence: **PASS**
- SHADOW metadata propagation: **PASS**
- LIVE Fusion blend: **PASS**
- KRONOS-only isolation: **PASS**

Example end-to-end certification values:

- Fusion score before ADVL: `0.387`
- ADVL confirmation signal: `+0.400`
- Fusion score with 5% ADVL weight: `0.38765`

These are synthetic certification values, not trading-performance claims.

## Remaining live dependency

A genuine breadth feed must populate:

`C:\Abutron\TradingPlatformV4\runtime\advl_breadth.json`

with advancing and declining **market/universe volume**. XAUUSD tick volume must not be substituted and labeled ADVL.

PowerShell itself was not available in the Linux packaging environment, so the `.ps1` could not be executed here. Its Python payload, patch behavior, compile behavior, rollback design, and end-to-end integration logic were tested independently. The Windows server installer also re-runs the tests and production pytest suite before completion.
