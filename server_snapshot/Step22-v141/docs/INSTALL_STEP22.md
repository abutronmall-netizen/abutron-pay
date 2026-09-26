# Install Step 22 on the Windows VPS

1. Extract the release to `C:\Abutron\Step22`.
2. Administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location C:\Abutron\Step22
.\scripts\install_step22.ps1
```

3. Run the non-trading environment precheck:

```powershell
Set-Location C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway
.\scripts\step22_precheck.ps1
```

4. Review the inventory output before applying TLS. Do not apply a new Caddyfile blindly if an existing Caddy site is serving other applications.

5. When the Caddy inventory is understood and the binary is present:

```powershell
.\ops\apply_caddy.ps1 -Apply
```

6. Later, after real OAuth/DEMO/recovery certificates:

```powershell
.\scripts\step22_release_candidate.ps1 -UserId <ABUTRON_USER_ID> -AccountId <CTRADER_ACCOUNT_ID>
```

Step 22 never enables `CTRADER_LIVE_MONEY_AUTHORIZED`.
