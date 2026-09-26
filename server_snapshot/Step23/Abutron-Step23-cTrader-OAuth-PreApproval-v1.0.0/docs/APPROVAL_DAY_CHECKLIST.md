# Step 23 Approval-Day Checklist

1. Confirm Abutron FX status is **Approved**.
2. Rotate the previously exposed client secret if not already done.
3. Confirm redirect URI: `https://api.abutronfx.online/v1/ctrader/oauth/callback`.
4. Run `configure_ctrader_credentials.ps1`.
5. Run `step23_postapproval_readiness.ps1`.
6. Start OAuth with scope `trading`.
7. Authorize an IC Markets **demo** account first.
8. Exchange the returned authorization code immediately; cTrader documents it as short-lived.
9. Discover the `ctidTraderAccountId`.
10. Keep live money OFF and the kill switch ON.
11. Continue to Step 21C demo lifecycle certification.

Never paste client secrets, access tokens, refresh tokens or authorization codes into chat.
