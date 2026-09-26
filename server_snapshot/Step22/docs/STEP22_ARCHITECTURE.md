# Step 22 — Production perimeter and release-candidate hardening

Step 22 is deliberately additive. It does not alter Kronos, Fusion, Risk, Capital, Equity Router, bot policies, or the currently selected trading gateway.

## Goals
- Stage a minimal public HTTPS reverse proxy for `api.abutronfx.online`.
- Keep ports 8088, 8090 and 8091 localhost-only.
- Expose only customer auth/account/mobile/history routes and the browser OAuth start/callback endpoints.
- Keep internal execution, management, recovery and admin routes off the public proxy.
- Audit secret placeholders and broad writable ACLs without printing secret values.
- Create online-consistent SQLite backups via Python `sqlite3.Connection.backup`, hash them, and run `PRAGMA integrity_check` on copies.
- Provide repeatable local/public health monitoring.
- Keep live money disabled throughout Step 22.

## TLS
Caddy configuration is staged but not applied by the installer. `ops/apply_caddy.ps1 -Apply` is the explicit operator action after service/network inventory is reviewed. Caddy should run as a Windows service and obtain/renew the public certificate automatically once DNS and ports 80/443 are correct.

## Release candidate rule
Step 22 build/precert can pass before Spotware approval. `step22_release_candidate.ps1` cannot pass until public TLS works and the real Step 21B/21C/21D cTrader certifications are recorded as PASS. It still does not authorize live money.
