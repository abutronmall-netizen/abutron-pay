# Step 21B v1.1.1 -> v1.1.2 Repair

The v1.1.1 Core patch could succeed but route verification falsely failed because the Python verifier joined route paths with a literal `\n` sequence. PowerShell therefore received one long string, so `-contains` could not find individual routes and triggered rollback.

v1.1.2 emits one route per stdout line, normalizes the returned array, and keeps all Step 21B behavior zero-order.

Run from a fresh extracted source directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location C:\Abutron\Step21B-v112
.\scripts\install_step21b.ps1
```

Then:

```powershell
Set-Location C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway
.\scripts\step21b_precredential.ps1
```
