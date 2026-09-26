Abutron Production Server Safe GitHub Backup
Device: ABUTRON-PROD-01
Created: 2026-09-26T21:15:13.3249167+00:00
Source root: C:\Abutron
Backup branch: server-backup-20260926-2320

Included:
- application source
- PowerShell/Python deployment scripts
- tests and certification logic
- docs and manifests
- configuration examples/templates
- mobile source
- Jarvis source
- Step21-Step27 source packages
- ADVL integration source

Excluded from GitHub:
- .env files and FIRST_RUN_SECRETS
- secrets/data directories and database files
- private keys/certificates
- MT5 runtime/accounts
- virtual environments and dependencies
- caches/logs/runtime output
- model downloads
- old backups and ZIP archives
