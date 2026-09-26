ABUTRON JARVIS PHASE 2.1 PASSIVE PROBE PATCH

Purpose:
- Replaces Kronos and MT5 Bridge HTTP /health probes with localhost TCP-only probes.
- Prevents Jarvis health collection from invoking TradingPlatformV4 /health, which cascades to MT5 Bridge /health.
- Prevents Jarvis health collection from invoking MetaTrader5.initialize() through MT5 Bridge /health.
- Reads only non-secret safety flags from C:\Abutron\TradingPlatformV4\.env.
- Does not restart any service.

Changed files:
- app\monitoring\config.py
- app\monitoring\collectors.py
- tests\test_phase_2_1_health.py

Install from Administrator PowerShell:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_passive_patch.ps1

Do not activate/restart Jarvis until the patch tests pass and the next controlled activation step is approved.
