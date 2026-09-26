# Abutron Step 21 v1.1 — Controlled DEMO Execution Lifecycle Certification

## Purpose

Step 21 is the post-endurance controlled execution gate for ABUTRON Trading Platform v4.0. It does **not** enable production execution or live-money trading. It orchestrates the already-certified Step 19 broker lifecycle harness after requiring the Step 20 120-minute endurance certification.

## What Step 21 proves

In DEMO mode, for the selected tier(s), Step 21 requires the underlying Step 19 harness to prove:

- selected-tier broker lifecycle completed;
- stop-loss management did not worsen risk;
- normal close completed;
- database reconciliation is idempotent;
- broker and database position state agree;
- zero residual ABUTRON exposure remains;
- production idempotency state is untouched by certification;
- process-local certification settings are restored;
- production `.env` is unchanged;
- live-money authorization remains false.

Step 21 also requires a formal Step 20 PASS of at least 120 minutes, production execution switches OFF, DEMO-only ON, worker OFF, healthy Core/Bridge, and authenticated MT5 bridge reads.

## Deliberate safety architecture

Step 21 never changes these production switches:

```text
ABUTRON_EXECUTION_ENABLED=false
MT5_LIVE_TRADING=false
MT5_MANAGEMENT_ENABLED=false
MT5_DEMO_ONLY=true
```

DEMO orders are sent only through the existing Step 19 certification harness and only when the operator supplies `-AuthorizeDemo`.

## Modes

### PRECHECK
No broker order is authorized. Use this first.

### DEMO
Requires explicit `-AuthorizeDemo`. This is still DEMO-only and does not authorize live money.

## Tiers

- `FLIPPER` — uses the existing Step 19 selected-tier runner.
- `SCALPER` — uses Step 19 MultiDemo v1.4 and requires a Scalper certification DEMO login.
- `MASTER` — uses Step 19 MultiDemo v1.4 and requires a Master certification DEMO login.
- `ALL` — runs all three sequentially.

## Formal PASS target

```text
STEP21_ENV_IMMUTABILITY=PASS
STEP21_DEPENDENCY_IMMUTABILITY=PASS
WORKER_FINAL=OFF
PRODUCTION_LIVE_TRADING=OFF
PRODUCTION_MANAGEMENT=OFF
ABUTRON_EXECUTION=OFF
LIVE_MONEY_AUTHORIZED=False
STEP21=PASS
```

A Step 21 PASS is a DEMO execution certification only. It is not proof of profitability and is not live-money approval.


## v1.1 correction

- Uses the MT5 bridge's real authentication variable `MT5_API_TOKEN` (the bridge `api_token` field uses the `MT5_` environment prefix).
- Refuses placeholder tokens.
- Installation examples now collect demo logins with `Read-Host` so placeholder angle brackets cannot be pasted into PowerShell.
