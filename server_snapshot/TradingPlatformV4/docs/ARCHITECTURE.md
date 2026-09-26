# ABUTRON TRADING PLATFORM v4.0 — Canonical Architecture

```text
LIVE MARKET DATA
        ↓
KRONOS
        ↓
INSTITUTIONAL + TECHNICAL + REGIME
        ↓
FUSION
        ↓
CONFIDENCE
        ↓
THESIS
        ↓
BUY / SELL / HOLD
        ↓
RISK
        ↓
CAPITAL
        ↓
EQUITY ROUTER
        ↓
FLIPPER / SCALPER / MASTER
        ↓
MT5 GATEWAY
        ↓
BROKER
        ↓
ORDER EXECUTED
        ↓
MANAGED
        ↓
CLOSED
        ↓
DATABASE
        ↓
ADMIN
        ↓
MOBILE
```

## Architectural invariants

1. Kronos and feature engines may propose direction; they cannot authorize broker execution.
2. Risk and capital are authoritative and cannot be bypassed by strategy engines.
3. HOLD never creates an order plan.
4. A volume below broker minimum is rejected; the capital engine never forces a minimum lot that exceeds the risk budget.
5. Equity routing is sticky while positions are open. A tier transition occurs only when the account is flat.
6. Flipper, Scalper and Master consume the same approved thesis and differ only in execution policy/profile.
7. Orders are idempotent at the MT5 gateway.
8. Opposing positions are rejected by the gateway.
9. Live trading and position management require independent enable flags.
10. Database, admin and mobile are downstream observability/control surfaces; none may bypass risk/capital/execution gates.

## Equity routing

- $20.00–$3,000.00: FLIPPER
- >$3,000.00–$5,000.00: SCALPER
- >$5,000.00–$10,000.00: MASTER
- below $20: INELIGIBLE
- above $10,000: MANUAL_REVIEW until a dedicated tier is explicitly approved

## Execution flags

Production installs start with:

```text
ABUTRON_EXECUTION_ENABLED=false
MT5_LIVE_TRADING=false
MT5_MANAGEMENT_ENABLED=false
```

All three remain false until certification is complete.
