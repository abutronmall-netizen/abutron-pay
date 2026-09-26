# ABUTRON STEP 22 v1.4.0 — Production Perimeter

Builds on the VPS-passed Step 21D precert and adds release-perimeter hardening: staged Caddy TLS/public-route allowlisting, secret/ACL audit, online-consistent SQLite backup + verification, health monitoring, network inventory, and a fail-closed release-candidate gate.

**No live-money authorization is enabled. Step 22 does not change the Kronos trading execution selector.**

Install: `scripts\install_step22.ps1`  
Precheck: `scripts\step22_precheck.ps1`  
TLS apply (explicit): `ops\apply_caddy.ps1 -Apply`  
Release-candidate gate (later): `scripts\step22_release_candidate.ps1`
