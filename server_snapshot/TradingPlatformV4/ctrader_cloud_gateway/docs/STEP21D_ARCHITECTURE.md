# Step 21D — Failure / Recovery Architecture

## Invariants
- A broker mutation (`market-order`, `close-position`, `amend-position`) is never auto-retried after a transport ambiguity.
- Read-only requests may receive one bounded restart/retry after a worker pipe/not-ready failure.
- A disconnected cTrader worker exits and is recreated as a fresh app-authenticated process.
- OAuth refresh-token rotation is stored atomically; token values are never returned through Step 21D APIs.
- `UNCERTAIN` idempotency records survive process restarts in SQLite.
- Recovery inspection checks current reconciliation and order history for matching `clientOrderId`.
- Recovery inspection never sends an order, closes a position, or amends protection.
- `automatic_retry_allowed` is always false for recovery inspection.
- LIVE connection and LIVE money remain disabled.

## Recovery classification
1. `ACTIVE_ABUTRON_EXPOSURE` — current Abutron position/order exists; block retry.
2. `BROKER_MUTATION_OBSERVED` — historical order has matching clientOrderId; block retry.
3. `NO_BROKER_EVIDENCE_RETRY_STILL_BLOCKED` — no evidence found but ledger is UNCERTAIN; operator/audit decision required.
4. `LEDGER_*` — durable ledger has a known terminal/non-uncertain state.

This deliberately favors duplicate-trade prevention over automatic recovery speed.
