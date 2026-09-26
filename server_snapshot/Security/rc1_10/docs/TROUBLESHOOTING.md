# RC1-10 troubleshooting and remediation boundaries

RC1-10 is intentionally conservative. A FAIL means stop and inspect the evidence JSON before changing production.

## `AUTOADMINLOGON` FAIL
Do not simply disable AutoAdminLogon on the remote VPS. First determine whether the current MT5 startup/session design depends on an interactive Administrator session. This control is a release blocker because unattended administrator logon stores/uses credentials and expands the attack surface.

## `FIREWALL_*` FAIL
Do not enable/replace firewall rules blindly over RDP. Confirm provider-console/rescue access first, then repair the specific profile/rule while preserving HTTPS and the actual RDP management path.

## `LOOPBACK_PORT_*` FAIL
An internal/admin/monitoring service is listening outside loopback. Fix that service's bind address or explicitly isolate it at the firewall. Do not expose Kronos, MT5 bridge, Jarvis APIs, Grafana, Prometheus or the Caddy admin API publicly.

## `RDP_NLA` FAIL
NLA should be restored, but only after provider-console fallback is confirmed. RC1-10 does not automatically change NLA because doing so on a remote server can create a lockout if another policy/client issue exists.

## historical Event 41 / 6008 WARN
Historical unexpected shutdowns are expected to remain visible. They become a blocker only if new Event 41/6008 records appear after the RC1-10 pre-reboot certificate.

## Schannel 36874 WARN
Do not weaken TLS or NLA to make unknown/legacy clients connect. Identify the intended RDP client first.

## `LEGACY_SECRET_COPIES` FAIL
Run `Quarantine-RC1-10-LegacySecretCopies.ps1`; it DPAPI-encrypts and verifies legacy `.env.before/.bak/.old/.copy` files before deleting the plaintext copies.

## secret rotation attestation FAIL
The previously exposed cTrader/Spotware client secret must no longer be in use. Update the gateway with replacement credentials, verify the gateway, then record the attestation without entering the secret itself.

## integrity drift FAIL
Do not regenerate the baseline merely to make the test green. Determine whether the changed file/task was an approved RC change. If approved, redo the full pre-reboot audit and create a new baseline/certificate.

## final RDP gate not mature
The final certificate intentionally requires the configured uninterrupted-uptime window plus a real normal-RDP-access attestation because the server previously required manual reboot to regain access.
