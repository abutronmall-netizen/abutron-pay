# Abutron RC1-10 — Security / Release Audit v1.0.0

RC1-10 is a fail-closed release-security gate for the Abutron Trading Platform.

## RC1-10 control families

- **RC1-10.1** Secrets inventory, legacy-secret quarantine and rotation attestation
- **RC1-10.2** Windows permissions / scheduled-task integrity
- **RC1-10.3** Firewall, listener and public API exposure
- **RC1-10.4** TLS / certificate / Caddy validation
- **RC1-10.5** RDP reliability, NLA, listener and clean-shutdown evidence
- **RC1-10.6** Local encrypted rollback backup and SQLite restore test
- **RC1-10.7** SHA-256 integrity manifest protected by a machine DPAPI HMAC key
- **RC1-10.8** Trading/live-money safety assertions
- **RC1-10.9** Provider console + off-host snapshot attestation
- **RC1-10.10** Clean reboot and overnight RDP stability certification

## Safety design

The package does **not**:
- enable trading
- modify Kronos strategy logic
- modify MT5 order logic
- change RDP port
- disable RDP
- alter Windows Firewall allow rules
- alter Caddy routes
- alter TLS cipher order
- automatically apply the full Microsoft Windows Server 2025 OSConfig security baseline
- print secret values

The only automatic hardening action is restricting live `.env` secret-file ACLs to local Administrators and SYSTEM. The previous ACLs are recorded for rollback.

## Certification levels

1. `PRE_REBOOT_CERTIFIED=True`
2. `POST_REBOOT_CERTIFIED=True`
3. `RC1_10_CERTIFIED=True`

The final level deliberately requires an overnight-style RDP stability window because the server previously showed recurring morning login/reboot problems.

The final RDP gate also requires a user attestation that normal RDP access succeeded without a manual/provider hard reset after the unattended stability window.
