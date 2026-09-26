# Step 21B — Windows installation

1. Prerequisite: Step 21A v1.0.1 must already show `STEP21A_PREAPPROVAL=PASS`.
2. Extract this package to `C:\Abutron\Step21B`.
3. Administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location C:\Abutron\Step21B
.\scripts\install_step21b.ps1
.\scripts\step21b_precredential.ps1
```

4. Keep live and demo execution disabled. Do not change the kill switch.
5. After Spotware approval, add only `CTRADER_CLIENT_ID` and `CTRADER_CLIENT_SECRET` to `C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway\.env`.
6. Start/restart the gateway: `C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway\scripts\start_gateway.ps1`.
7. In the Abutron app/API, authenticated customer calls `POST /v1/broker/ic-markets/connect` and completes cTrader OAuth.
8. Refresh accounts: `POST /v1/broker/ic-markets/accounts/refresh`.
9. Run zero-order certification:

```powershell
Set-Location C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway
.\scripts\step21b_certify.ps1 -UserId <ABUTRON_USER_ID>
```

If the discovered account currency is not USD, certification may still prove OAuth/account/symbol discovery, but the USD equity router stays blocked with `CURRENCY_CONVERSION_REQUIRED`. For the September 30 launch path, use a USD-denominated IC Markets cTrader account unless a separately certified currency-conversion layer is added.
