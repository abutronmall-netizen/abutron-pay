# ABUTRON FX — private broker trade-history archive

**Private GitHub branch only.** Data was exported read-only from available Deriv and FP Markets MT5 native exports at the manifest timestamp. Per-account compressed CSV files contain trade-execution deals; FP Markets also has a latest available open-position snapshot, which is not execution history. Each broker/account has a SHA-256 file manifest.

The native history sources include selected export windows and older archived snapshots, not proof of complete lifetime trading history. Records are deduplicated by broker ticket and no claims are made about live position exposure or order execution. Missing retired accounts are documented, not reconnected. Nontrading financial account events, deposits, withdrawals, credentials, balances and account fingerprints are excluded. **Do not merge this branch into a public branch.**

To inspect: `gzip -dc Deriv/DEMO-6207/deals.csv.gz | head` (same pattern for other accounts).
