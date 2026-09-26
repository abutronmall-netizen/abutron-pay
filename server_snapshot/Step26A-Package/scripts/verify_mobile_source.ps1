param(
    [string]$MobileRoot="C:\Abutron\TradingPlatformV4\mobile\AbutronMobile"
)
$ErrorActionPreference="Stop"

if(-not(Test-Path $MobileRoot)){throw "MOBILE_ROOT_NOT_FOUND=$MobileRoot"}
Set-Location $MobileRoot

$required=@("App.tsx","package.json","app.json","tsconfig.json","eas.json","src\api.ts","src\types.ts","src\ui.tsx")
foreach($r in $required){
    if(-not(Test-Path (Join-Path $MobileRoot $r))){throw "MOBILE_FILE_MISSING=$r"}
}

$pkg=Get-Content ".\package.json" -Raw|ConvertFrom-Json
if($pkg.dependencies.expo -ne "~57.0.0"){throw "EXPO_VERSION_UNEXPECTED"}
if($pkg.dependencies.'react-native' -ne "0.86.0"){throw "REACT_NATIVE_VERSION_UNEXPECTED"}

$source=(Get-Content ".\App.tsx" -Raw)+(Get-Content ".\src\api.ts" -Raw)
if($source -match "/v1/order|Place Order|order_send"){throw "MOBILE_EXECUTION_UI_REFERENCE_FOUND"}

Write-Host "STEP26A_MOBILE_SOURCE_FILES=PASS"
Write-Host "STEP26A_MOBILE_VERSION_CONTRACT=PASS"
Write-Host "STEP26A_MOBILE_NO_ORDER_UI=PASS"
Write-Host "STEP26A_MOBILE_SOURCE=PASS"
