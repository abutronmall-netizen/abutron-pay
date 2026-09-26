# Abutron Step 20 V1.1 — Soak / Endurance Certification

Build marker: `STEP20_SOAK_ENDURANCE_CERT_V1_1`

This repair release fixes preflight error visibility under Windows PowerShell and strengthens soak isolation. It does not enable broker execution.

## Safety prerequisites

- `ABUTRON_EXECUTION_ENABLED=false`
- `MT5_LIVE_TRADING=false`
- `MT5_MANAGEMENT_ENABLED=false`
- `MT5_DEMO_ONLY=true`
- production worker OFF before starting
- MT5 connected to the canonical production-pinned DEMO login/server from `.env`
- no open positions or pending orders on the certification account
- do not manually trade during the soak

## File hashes

- `step20_soak_probe_v1_1.py`: `012A0929E0438F086502D793200779ADC3F5C1478FDAB0214CA59F617FFCAEED`
- `Abutron-Step20-Soak-Endurance-Cert-v1.1.ps1`: `ED4067A4CB63B72D16FDA520C337F3988E6773E9D7F9483CD158C4B96FBC9B24`
- `Abutron-Step20-Install-Validate-Preflight-v1.1.ps1`: `AE94236D387ED61DD05F580A2EC8137E111885CE134A0A8ED98D979F620AFCFF`

## Sequence

1. Extract the bundle into `C:\Abutron\TradingPlatformV4\scripts`.
2. Run `Abutron-Step20-Install-Validate-Preflight-v1.1.ps1`.
3. If preflight reports PASS, run a 15-minute diagnostic:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Abutron\TradingPlatformV4\scripts\Abutron-Step20-Soak-Endurance-Cert-v1.1.ps1" -DurationMinutes 15 -SampleSeconds 15 -DiagnosticOnly`
4. Review the diagnostic. Only after DIAGNOSTIC_PASS, run the 120-minute certification:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Abutron\TradingPlatformV4\scripts\Abutron-Step20-Soak-Endurance-Cert-v1.1.ps1" -DurationMinutes 120 -SampleSeconds 15`
5. A true certification PASS writes `C:\Abutron\TradingPlatformV4\logs\step20_certification.json`.

If any gate fails, do not rerun blindly. Preserve the newest logs and review the exact failure first.
