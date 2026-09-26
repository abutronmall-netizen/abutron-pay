# ABUTRON STEP 21D v1.3.0 — cTrader Failure / Recovery Hardening

Builds on the VPS-passed Step 21C precert. This stage adds fail-closed recovery for transport loss, worker restart, OAuth token rotation, durable UNCERTAIN idempotency inspection and broker order-history matching by `clientOrderId`.

**No live-money authorization is enabled. No mutation is automatically retried.**

Install: `scripts\install_step21d.ps1`  
Precheck: `scripts\step21d_precheck.ps1`  
Real OAuth recovery cert (later): `scripts\step21d_certify.ps1 -UserId <id> -AccountId <ctidTraderAccountId>`
