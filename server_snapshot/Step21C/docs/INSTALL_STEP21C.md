# Install Step 21C v1.2.0

1. Extract to `C:\Abutron\Step21C`.
2. Administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location C:\Abutron\Step21C
.\scripts\install_step21c.ps1
```

3. Run build/precert (zero order):

```powershell
Set-Location C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway
.\scripts\step21c_precheck.ps1
```

Do not run `step21c_certify.ps1 -AuthorizeDemo` until Spotware credentials are installed and Step21B real OAuth discovery has passed.
