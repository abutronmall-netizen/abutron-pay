# Step 21C Architecture

Step 21C adds a customer cTrader execution adapter without replacing the global MT5 gateway.

Market data for Kronos remains centralized on the already-certified market-data bridge. Customer account equity, positions, symbol economics and live execution quote come from the OAuth-bound IC Markets cTrader DEMO account. Risk/Capital/Equity Router therefore size the customer order from customer state, not VPS MT5 account state.

Safety: Step21B real OAuth discovery PASS is mandatory; DEMO only; live connection false; live money false; explicit `-AuthorizeDemo`; kill switch/runtime gates are restored after certification.

Important Spotware constraint: absolute SL/TP are unsupported on MARKET orders. Step 21C uses relative protection on the market order and position-level amend/reconciliation after fill.
