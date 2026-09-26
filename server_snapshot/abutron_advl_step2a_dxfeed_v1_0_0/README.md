# Abutron ADVL Step 2A - dxFeed Market Indicators v1.0.0

This package connects the already-installed Abutron ADVL v1.0.1 sidecar to genuine NYSE/Nasdaq advancing-volume and declining-volume market breadth.

## Selected production source

dxFeed Market Indicators, using the **composite** symbols:

- `$UVOLC` - NYSE Composite Advanced Volume
- `$DVOLC` - NYSE Composite Declined Volume
- `$UVOLC/Q` - NASDAQ Composite Advanced Volume
- `$DVOLC/Q` - NASDAQ Composite Declined Volume

dxFeed publishes these values as session-cumulative totals. The collector first converts them to **interval deltas** so the already-installed ADVL accumulator cannot double-count the same shares on every poll. It then sums NYSE + Nasdaq interval advancing volume and NYSE + Nasdaq interval declining volume and atomically writes:

`C:\Abutron\TradingPlatformV4\runtime\advl_breadth.json`

The existing `abutron\advl.py` consumes that file. No additional Kronos/Fusion patch is required.

## Why composite indicators

The composite variants represent NYSE/Nasdaq-listed stocks traded across CTA/UTP participants rather than only the primary listing exchange. This makes them the better production breadth input for a consolidated market view.

## Safety

- ADVL stays in SHADOW mode. This package never sets `ABUTRON_ADVL_MODE=live`.
- Demo/delayed dxFeed data is never written to the Kronos feed unless explicitly overridden.
- All four components must be present, non-negative, fresh, and time-aligned.
- Provider session-cumulative values are persisted separately and converted to interval deltas before Kronos sees them.
- First sample, long collector gaps, and provider/session resets re-prime the baseline and intentionally produce no ADVL feed update.
- The feed timestamp is the **oldest** of the four component timestamps, so freshness is conservative.
- Invalid or stale provider data does not overwrite the last good feed; it naturally becomes stale inside the existing ADVL sidecar.
- Every unique valid sample is persisted to NDJSON for OOS/forward validation.
- The Windows task runs as SYSTEM, starts at boot, and restarts after failures.

## Transport choice

Step 2A intentionally uses 5-second REST polling while ADVL is in shadow validation. Four vendor-computed indicators are fetched in one request, so this avoids ingesting thousands of stock trades and remains well below the normal dxFeed REST request limit. After OOS/forward evidence is positive, a later step can migrate the collector to dxLink/WebSocket streaming before ADVL is considered for live Fusion influence.

## Required production access

Request dxFeed **B2B** real-time Market Indicators API entitlement. The retail platform prices shown on public order pages are not assumed to apply to Abutron's commercial/server-side use. Ask dxFeed for a production REST endpoint, token/credentials, and commercial licensing terms. A ready-to-send request is included as `dxFeed-Access-Request.txt`.

## Installation outline

1. Install this package.
2. Request/receive dxFeed production API access.
3. Edit `C:\Abutron\TradingPlatformV4\secrets\dxfeed_advl.env`.
4. Run one-shot validation (no feed write).
5. Change `DXFEED_MODE=production` and validate again.
6. Register/start the scheduled task.
7. Run `Verify-Abutron-ADVL-Step2A.ps1` to prove dxFeed interval data reaches the installed ADVL sidecar.
8. Verify `advl_breadth.json`, `advl_dxfeed_status.json`, `advl_dxfeed_source_state.json`, and the existing `advl_state.json`.
9. Keep ADVL SHADOW until OOS + forward testing is complete.
