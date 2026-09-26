# A/B/C validation

Use the same broker history, spread/commission assumptions, starting equity and risk rules for all modes.

Run three passes:
- `ABUTRON_CORE_MODE=KRONOS`
- `ABUTRON_CORE_MODE=INSTITUTIONAL`
- `ABUTRON_CORE_MODE=FUSION`

For final selection, compare out-of-sample expectancy, profit factor, maximum drawdown,
Sharpe/Sortino, recovery factor, trade count, cost sensitivity and regime stability.

The production worker must stay disabled while backtesting.
