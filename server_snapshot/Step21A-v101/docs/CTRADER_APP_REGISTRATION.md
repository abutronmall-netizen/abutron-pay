# cTrader Open API application registration

Application name: **Abutron Trading Platform**

Website: `https://abutronfx.online`

Production redirect URI (add after approval):
`https://api.abutronfx.online/v1/ctrader/oauth/callback`

Requested scope in the Abutron OAuth flow: `trading`

Suggested description:

> Abutron Trading Platform is a customer-authorised cloud trading application for IC Markets cTrader users. Customers sign in with cTrader ID and explicitly grant trading permission to their own accounts. Abutron does not request or store cTrader passwords. Its Kronos decision engine, risk engine, capital engine and equity router produce controlled trade instructions that are executed through cTrader Open API, with account ownership checks, stale-command protection, idempotency, audit logs, kill switches and broker reconciliation. Development and certification are performed on DEMO before any live-money authorisation.

After submission the app is reviewed by Spotware. Do not guess client credentials and do not use playground redirect URIs in production.
