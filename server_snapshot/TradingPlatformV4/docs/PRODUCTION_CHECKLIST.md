# Production checklist

1. Windows MT5 terminal installed and logged into the intended account.
2. Python 3.11 x64 + Git installed.
3. Run `scripts/install_windows.ps1`.
4. Replace both API tokens in `.env`.
5. Confirm `ABUTRON_EXECUTION_ENABLED=false`.
6. Confirm `MT5_LIVE_TRADING=false`.
7. Start MT5 bridge and core.
8. Run `scripts/smoke_test.ps1`.
9. Run A/B/C historical tests using identical data and costs.
10. Complete walk-forward and untouched holdout validation.
11. Demo-forward test.
12. Small controlled live rollout.
13. Only then enable BOTH execution flags.
14. Keep daily loss and spread rejection enabled.
15. Review `/admin` decision telemetry daily.
