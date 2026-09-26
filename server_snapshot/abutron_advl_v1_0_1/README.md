# Abutron ADVL Integration v1.0.1

This package adds a real **Advance/Decline Volume Line (ADVL)** confirmation feature to the server-side Abutron Kronos core.

## Safety design

- **Shadow mode is the default.** ADVL is calculated and logged but cannot alter BUY/SELL/HOLD.
- **KRONOS-only mode is never modified by ADVL.**
- Missing, invalid, stale, out-of-order, or low-quality breadth data is fail-neutral and cannot alter a trade.
- The patcher backs up `abutron/fusion.py` before any write.
- No `FeatureVector` schema changes are required; ADVL diagnostics are stored under `features.metadata["advl"]`.
- Live Fusion weight is capped at 10% by code; recommended initial validated value is **5%**.


## Release verification

This package passed **15 standalone unit tests**, synthetic `fusion.py` patch/compile validation, idempotence validation, SHADOW metadata propagation, LIVE Fusion blend validation, and KRONOS-only isolation. See `VERIFICATION.md`.

## Required data

A genuine ADVL needs a breadth universe with **advancing volume** and **declining volume**. Do not substitute XAUUSD tick volume and call it ADVL.

Expected runtime file:

`C:\Abutron\TradingPlatformV4\runtime\advl_breadth.json`

Example:

```json
{
  "timestamp": 1790438400,
  "advancing_volume": 1823456789,
  "declining_volume": 1467890123,
  "source": "YOUR_BREADTH_PROVIDER",
  "universe": "NYSE"
}
```

The sidecar persists the cumulative line to `runtime\advl_state.json` and converts its recent change into a bounded `[-1, +1]` confirmation score.

## Install

Run in **Administrator PowerShell**:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd <folder-containing-this-package>
.\Install-Abutron-ADVL-v1.0.ps1
```

The installer runs standalone tests, backs up Fusion, installs the module, compiles the production package, runs the existing pytest suite, and leaves ADVL in shadow mode.

## Environment controls

```text
ABUTRON_ADVL_MODE=shadow              # default; no trade impact
ABUTRON_ADVL_FILE=<runtime feed path>
ABUTRON_ADVL_STATE_FILE=<state path>
ABUTRON_ADVL_LOOKBACK=20
ABUTRON_ADVL_MAX_AGE_SECONDS=900
ABUTRON_ADVL_MIN_QUALITY=0.75
ABUTRON_ADVL_MIN_ABS_SIGNAL=0.10
ABUTRON_ADVL_FUSION_WEIGHT=0.05
```

Only after OOS and forward validation should `ABUTRON_ADVL_MODE=live` be considered. In live mode the sidecar still requires freshness, quality, and minimum signal-strength gates before it can contribute.


## v1.0.1 installer fix

The PowerShell installer is now ASCII-safe for Windows PowerShell 5.1. The previous package contained one UTF-8 em dash in the installer; Windows PowerShell 5.1 could misread it as a smart quote and throw a parser error before execution. No ADVL Python trading logic changed in v1.0.1.
