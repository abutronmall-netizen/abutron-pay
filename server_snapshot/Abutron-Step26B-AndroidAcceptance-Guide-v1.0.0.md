# Abutron Step 26B — Android Real-Device Acceptance

## Purpose

This stage certifies the signed **Android preview build** on a real Android device. It does not enable live trading.

## Before running

1. Install the latest EAS preview APK on the Android phone using the QR code or install link from the successful EAS build.
2. Use a dedicated test customer account.
3. For the first connectivity test, disable Wi-Fi and use mobile data.
4. Keep `ABUTRON_EXECUTION_ENABLED`, MT5 live trading, and management disabled.

## Run the acceptance harness

Copy the PowerShell script to:

`C:\Abutron\Abutron-Step26B-AndroidAcceptance-v1.0.0.ps1`

Then Administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location C:\Abutron

.\Abutron-Step26B-AndroidAcceptance-v1.0.0.ps1
```

The script first verifies:
- local API health;
- execution/live-trading/management OFF;
- public `/healthz`;
- authenticated customer/mobile routes reach the backend;
- trading/admin/OpenAPI/internal-health routes remain public 404.

It then asks you to enter `PASS` or `FAIL` for each real-device test.

## PASS criteria

All required device tests must be `PASS`, and the final server safety check must still show:
- `execution_enabled = false`
- `live_trading = false`
- `management_enabled = false`
- `live_money_authorized = false`

A successful report is written to:

`C:\Abutron\TradingPlatformV4\certification\step26b\android\STEP26B_ANDROID_ACCEPTANCE_<timestamp>.json`

After Android acceptance passes, proceed to the signed iOS preview build and iPhone acceptance. Do not build/store-submit production binaries until both preview/device gates pass.
