# Abutron Step 22 v1.4.1 — Production Perimeter Repair

Repair release for the Step 22 VPS precheck. A missing `ctrader_gateway.db` before real OAuth is now recorded as `DEFERRED_NO_DB` instead of causing a false backup failure. Existing SQLite databases and environment files are still backed up, hashed, integrity-checked, and ACL-restricted.

The release-candidate gate still requires the real cTrader database plus Step 21B/21C/21D real certifications. Live-money authorization remains false.
