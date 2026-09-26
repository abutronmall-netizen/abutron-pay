# Step 22 v1.4.0 → v1.4.1 Repair

## Reason
On the VPS, Step 22 v1.4.0 correctly found that `C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway\data\ctrader_gateway.db` does not yet exist. That database is created by the cTrader gateway after real OAuth-backed use. v1.4.0 incorrectly treated the pre-OAuth absence as a backup failure.

## Repair
- Back up every SQLite database that actually exists.
- Require at least one real SQLite database to be backed up and integrity-checked.
- Record missing databases in the backup manifest as deferred.
- Emit `CTRADER_DB_BACKUP=DEFERRED_NO_DB` before real OAuth rather than creating a fake DB.
- Keep the final release-candidate gate blocked until the real cTrader DB exists.
- No trading logic or execution flags are changed.
