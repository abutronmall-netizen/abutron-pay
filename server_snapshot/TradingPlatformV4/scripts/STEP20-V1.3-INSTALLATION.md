# Abutron Step 20 V1.3 — Soak / Endurance Certification

## What V1.3 fixes

V1.3 corrects the V1.2 assumption that the strategy engine lives in a single `abutron\strategies.py` file. The production implementation is a strategy package under `abutron\strategies\`. V1.3 validates and hashes the package source set instead.

V1.3 also validates the authenticated read-only MT5 Bridge contract before the worker starts and uses the bearer token for periodic bars/context probes during the soak.

## Safety state

The production worker must be OFF before starting. Production `.env` must keep:

- `ABUTRON_EXECUTION_ENABLED=false`
- `MT5_LIVE_TRADING=false`
- `MT5_MANAGEMENT_ENABLED=false`
- `MT5_DEMO_ONLY=true`

The certification process never authorizes live money.

## Files

- `step20_soak_probe_v1_3.py`
- `Abutron-Step20-Soak-Endurance-Cert-v1.3.ps1`
- `Abutron-Step20-Install-Validate-Preflight-v1.3.ps1`

## Component SHA256

- helper: `442C5F46A400E3AF7A3E5BE4D7534F72A97B2745D6955308E04CE5517A6CE9A2`
- runner: `3ED6E024FC2FBBEE2CA3625052F40CBF551CA6D764BD783F37F74410A0C69F76`
- installer: `142BC36DBA689CA6CD6F6F6BFDC4517AED3D5B8F8F50500AA8FC2B299EBFF1BE`

## Sequence

1. Install/extract V1.3 into `C:\Abutron\TradingPlatformV4\scripts`.
2. Run the V1.3 installer/preflight.
3. Only if preflight exits 0, run a 15-minute diagnostic:

```powershell
powershell.exe `
  -NoProfile `
  -ExecutionPolicy Bypass `
  -File "C:\Abutron\TradingPlatformV4\scripts\Abutron-Step20-Soak-Endurance-Cert-v1.3.ps1" `
  -DurationMinutes 15 `
  -SampleSeconds 15 `
  -DiagnosticOnly
```

4. Review the diagnostic output before running the 120-minute certification.
