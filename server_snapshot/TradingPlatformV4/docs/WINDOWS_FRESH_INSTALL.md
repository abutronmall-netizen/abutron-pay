# Fresh Windows Deployment — ABUTRON v4.0

## 1. Prepare Windows

Use Windows Server 2022/2025 or Windows 11 Pro on the trading host. Install all updates and reboot.

Install:
- Python 3.11 x64 (enable `py` launcher)
- Git for Windows
- MetaTrader 5 from the approved broker
- Docker Desktop/Engine if PostgreSQL + Redis are being hosted locally
- Caddy if this host will expose the API over HTTPS

## 2. Copy the release

Extract `ABUTRON_TRADING_PLATFORM_v4_0.zip` to:

```powershell
C:\Abutron\TradingPlatformV4
cd C:\Abutron\TradingPlatformV4
```

## 3. Install dependencies

Open PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\install_windows.ps1 -UsePostgres
```

For an offline/single-host validation install using SQLite:

```powershell
.\scripts\install_windows.ps1
```

The installer generates `.env` secrets and writes the first-run admin credentials to `FIRST_RUN_SECRETS.txt`. Store them securely and delete that file after use.

## 4. Configure MT5

1. Open MT5 and log into the demo/production account.
2. Enable required symbols in Market Watch.
3. Confirm XAUUSD or the broker-specific equivalent is visible.
4. Leave Algo Trading unchanged: v4 communicates through the local Python MT5 integration.
5. Do not enable Abutron live execution yet.

## 5. Start v4

```powershell
.\scripts\start_platform.ps1
```

Open:

```text
http://127.0.0.1:8088/admin
```

## 6. Dry-run certification

```powershell
.\scripts\certify_live.ps1
```

Confirm the returned pipeline contains every stage from LIVE MARKET DATA through the strategy and MT5 dry-run stage.

## 7. Production database

When `-UsePostgres` is used, the installer sets:

```text
ABUTRON_PLATFORM_DB_URL=postgresql+psycopg://...
```

Back up PostgreSQL before enabling execution and perform a restore drill.

## 8. HTTPS

Edit `deployment\caddy\Caddyfile` and set the production domain. Point DNS to the server and run Caddy as a Windows service. Firewall should expose only required HTTPS ports; the core (8088), MT5 gateway (8090), PostgreSQL and Redis should remain local/private.

## 9. Enable in three steps

Do not change all safety switches at once.

1. Dry run: all false.
2. Demo execution: set `ABUTRON_EXECUTION_ENABLED=true` and `MT5_LIVE_TRADING=true`; keep `MT5_MANAGEMENT_ENABLED=false` for the first order lifecycle.
3. After open/close reconciliation passes, set `MT5_MANAGEMENT_ENABLED=true` and validate break-even/trailing management.

## 10. Live certification

Start with the broker demo environment, then a deliberately low-risk live certification. Verify order/deal tickets, volume, SL/TP, close, database record, admin visibility and mobile visibility before declaring production PASS.
