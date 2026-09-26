# RC1-10 — step-by-step installation and certification

## 0. Important release rule
Run all commands from **Administrator PowerShell**.

Do not enable live trading during RC1-10.

Do not change RDP/firewall/TLS settings outside the package while the integrity baseline is active.

## 1. Copy and extract the package

Place:

`Abutron_RC1-10_Security_Release_Audit_v1.0.0.zip`

in:

`C:\Abutron\Packages`

Then:

```powershell
cd C:\Abutron\Packages

Expand-Archive `
  .\Abutron_RC1-10_Security_Release_Audit_v1.0.0.zip `
  . `
  -Force

cd C:\Abutron\Packages\Abutron_RC1-10_Security_Release_Audit_v1.0.0

Set-ExecutionPolicy `
  -Scope Process `
  -ExecutionPolicy Bypass `
  -Force

.\scripts\Install-RC1-10-v1.0.0.ps1
```

Expected:

```text
PASS release safety: execution OFF / RC1-08 OBSERVE_ONLY / RC1-09 NOTIFY_ONLY
PASS RC1-10 files installed with restricted ACL
RC1_10_INSTALLED=True
```

After installation use the live RC1-10 directory:

```powershell
cd C:\Abutron\Security\rc1_10
```

## 2. Apply the safe secret-file ACL hardening

```powershell
.\scripts\Apply-RC1-10-SafeHardening.ps1
```

This changes **only** ACLs on live `.env` files and the RC1-10 evidence tree.

It does not change RDP, firewall rules, Caddy routes, trading, MT5 or TLS ciphers.

If necessary, ACLs can be restored with:

```powershell
.\scripts\Restore-RC1-10-EnvAcl.ps1
```

## 3. Quarantine old plaintext secret copies

The historical project files include `.env.before_*` style copies. Encrypt and remove those plaintext copies before rotation/audit:

```powershell
.\scripts\Quarantine-RC1-10-LegacySecretCopies.ps1
```

The script DPAPI-encrypts each legacy file into the restricted RC1-10 backup tree, verifies decryption/hash equality, and only then removes the plaintext original.

## 4. Rotate the previously exposed cTrader/Spotware secret

Use the cTrader Open API application portal / application credentials workflow.

Do **not** paste the new secret into ChatGPT.

Update the server through the same secure environment/config path already used by the cTrader gateway.

If the portal does not provide a secret-regeneration control, use replacement application credentials or contact Spotware rather than continuing with the exposed secret.

After changing the secret, restart only the relevant cTrader gateway/service using its existing deployment procedure and verify the main trading core still reports:

```text
execution_enabled = false
mt5.live_trading = false
```

## 5. Create a provider/off-host recovery point

Before continuing, create a current VPS provider snapshot or another off-host backup.

Also verify you can access the provider console/rescue path if RDP fails.

RC1-10 records this as an attestation but does not automate your VPS provider account.

## 6. Record release attestation

```powershell
.\scripts\Set-RC1-10-ReleaseAttestation.ps1
```

Answer all questions truthfully.

No secret values are requested.

All answers must be YES.

## 7. Run the entire pre-reboot audit

```powershell
.\scripts\Run-All-RC1-10-PreReboot.ps1
```

This runs:
- platform safety
- secret/ACL scan
- firewall/listener/public exposure
- Caddy validation
- public TLS certificate validation
- RDP/NLA/listener checks
- historical shutdown review
- encrypted rollback backup
- SQLite online backup + quick_check + restore test
- Microsoft Server 2025 baseline readiness advisory
- code/config/task integrity baseline
- HMAC verification

If a control returns FAIL, stop and resolve that control. Do not bypass it.

Warnings are printed into JSON reports in:

`C:\Abutron\Security\rc1_10\reports`

## 8. Create the pre-reboot certificate

When the complete audit passes:

```powershell
.\scripts\Certify-RC1-10-PreReboot.ps1
```

Expected:

```text
PRE_REBOOT_CERTIFIED=True
NEXT=Restart-Computer...
```

## 9. Perform a controlled Windows reboot

```powershell
Restart-Computer
```

Reconnect through normal RDP.

Do not use a forced power reset.

## 10. Post-reboot certificate

After reconnecting by RDP:

```powershell
cd C:\Abutron\Security\rc1_10

Set-ExecutionPolicy `
  -Scope Process `
  -ExecutionPolicy Bypass `
  -Force

.\scripts\Certify-RC1-10-PostReboot.ps1
```

The script verifies:
- reboot occurred after the pre-certificate
- Jarvis/RC1-08/RC1-09/Prometheus persisted
- RC1-09 remains NOTIFY_ONLY
- active RDP reconnect is visible
- NLA remains enabled
- no unexpected shutdown Event 41/6008 occurred after the pre-certificate
- firewall/public exposure/TLS still pass
- integrity manifest still verifies
- secret controls still pass

Expected:

```text
POST_REBOOT_CERTIFIED=True
FINAL_RDP_STABILITY_GATE=PENDING
```

## 11. Final RDP stability gate

Because this VPS previously had recurring morning login/manual-reboot behavior, RC1-10 does not waive that history.

The policy requires at least **8 hours of uninterrupted uptime** after the clean reboot.

At the next suitable RDP login after that uptime requirement has been met, first record the real access result:

```powershell
cd C:\Abutron\Security\rc1_10

.\scripts\Set-RC1-10-RdpStabilityAttestation.ps1
```

This asks whether the server stayed up through the unattended/overnight period, whether normal RDP login succeeded **without first rebooting**, and whether no provider-console hard reset was needed.

Then run:

```powershell
.\scripts\Certify-RC1-10-Final.ps1
```

The final script again checks:
- uptime threshold
- active RDP session
- no unexpected shutdown since boot
- NLA/listener
- network/TLS/public deny
- integrity
- secret/rotation controls
- trading remains disabled

Expected final output:

```text
RC1_10_CERTIFIED=True
RC1-10 — Security / Release Audit CERTIFIED
NEXT=RC1-11 Strategy OOS / Forward Performance
```

## 12. Status command

At any point:

```powershell
.\scripts\Get-RC1-10-Status.ps1
```

## Release decision

Do not mark RC1-10 complete from the package build alone.

The package is the security candidate. The final release state becomes certified only after the live VPS pre-reboot, post-reboot and RDP stability gates all pass.
