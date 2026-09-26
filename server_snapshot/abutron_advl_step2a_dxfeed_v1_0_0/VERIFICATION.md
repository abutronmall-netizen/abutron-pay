# Verification - Abutron ADVL Step 2A dxFeed v1.0.0

Local package verification covers collector logic without requiring external credentials.

Checks:
- syntax compile
- synthetic dxFeed TimeAndSale parsing
- NYSE + Nasdaq composite aggregation
- provider cumulative-volume to interval-delta conversion (prevents repeated-volume double counting)
- source reset and long-gap re-prime behavior
- conservative oldest-component timestamp
- missing-symbol rejection
- negative-volume rejection
- stale-data rejection
- component-skew rejection
- future-timestamp rejection
- demo/no-write safety
- production atomic feed write
- history de-duplication
- production credential requirement
- millisecond timestamp normalization
- latest-event selection
- extra-response-field tolerance
- conservative default polling interval

The package does not claim a live dxFeed connection until the VPS is configured with a real production endpoint and entitlement supplied by dxFeed.

Additional local E2E certification used a synthetic dxFeed cumulative pair -> interval-delta collector output -> the installed ADVL v1.0.1 `compute_advl_feature` path and confirmed a valid shadow feature with no repeated-volume double counting.
