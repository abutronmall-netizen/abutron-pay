# Step 21A architecture decision

## Decision
Use cTrader Open API as a dedicated localhost broker microservice with an isolated Python venv and long-lived connection workers.

## Why
1. Spotware recommends at most two Open API connections: one DEMO and one LIVE, with multiple accounts per connection.
2. The official Python SDK is Twisted-based and pins older protobuf/OpenSSL dependencies; isolation prevents dependency collision with Kronos.
3. Kronos stays broker-agnostic. The gateway owns OAuth, ctidTraderAccountId, cTrader symbols/protocol volume, broker reconciliation and broker-specific failures.
4. Live-money controls stay physically separate from DEMO controls.
5. Atomic idempotency prevents concurrent duplicate orders. Ambiguous failures are marked UNCERTAIN and must be reconciled, not blindly retried.

## Service boundary
Abutron Mobile -> Abutron Core -> Kronos/Risk/Capital/Router/Bot -> localhost cTrader Gateway -> persistent DEMO/LIVE Open API worker -> IC Markets cTrader account.

## Step 21A scope
Foundation + install + safety + persistent transport + OAuth/token/account/read/trade APIs. It is code-ready for real credentials, but broker certification begins only after Spotware approval.

## IC Markets-only release boundary
Step 21A normalizes `brokerTitleShort` and only persists accounts matching the configured IC markers (`ICMARKETS` or `RAWTRADING` by default). Other cTrader broker accounts authorised under the same cTID are ignored and audited.
