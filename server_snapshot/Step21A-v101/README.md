# Abutron Step 21A — IC Markets cTrader Cloud Gateway v1.0.1

Production-oriented foundation for the 30 September 2026 controlled-release track.

**This release does not authorize live money and installs with broker execution disabled.**

Key changes versus the Day-1 prototype:
- dedicated `.venv_ctrader` so Spotware SDK dependencies cannot destabilize Kronos;
- persistent DEMO/LIVE worker architecture instead of one connection per command;
- app-auth-once / account-auth-per-customer flow using `ctidTraderAccountId`;
- heartbeat, queue/serialization boundary and automatic worker restart on pipe failure;
- atomic idempotency reservation with `UNCERTAIN` fail-closed state;
- OAuth token encryption/refresh and one-time link tickets;
- explicit protocol-volume boundary and risk-safe lot conversion helper;
- market order, reconcile, symbol, symbol-detail, close and amend-SL/TP paths;
- additive core HTTP adapter; Step 21A does not switch production TradingService automatically.

Start with `docs/INSTALLATION_STEP_BY_STEP.md`.

## Build status (25 September 2026)

```text
STEP21A_BUILD_STATIC=PASS
STATIC_TESTS=11/11 PASS
LOCAL_NO_CREDENTIAL_STARTUP=PASS
STEP21A_SERVER_INSTALL=PENDING
SPOTWARE_APP_APPROVAL=PENDING
REAL_IC_DEMO_OAUTH=PENDING
BROKER_ORDER_SENT=False
LIVE_MONEY_AUTHORIZED=False
```

Static/code PASS is not broker certification. Follow `docs/INSTALLATION_STEP_BY_STEP.md` and retain VPS evidence before advancing to Step 21B.


## v1.0.1 repair

Repairs the v1.0.0 Windows installer target-tree omission (`.env.example` and `core_integration`) while preserving the installed `.env`. See `docs/REPAIR_V1_0_0_TO_V1_0_1.md`.
