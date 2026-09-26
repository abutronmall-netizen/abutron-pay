# v4.0 — 100% Production Acceptance Gates

"100%" means every software gate and every external live-environment gate below has evidence. Code-complete is not the same as broker-certified or store-released.

| Stage | Automated gate | External/live gate | Complete when |
|---|---|---|---|
| Live Market Data | bars/context schema tests | live MT5 ticks/bars stay fresh across reconnect | PASS evidence retained |
| Kronos | model load + inference contract | production model/repo installed on VPS/GPU/CPU target | deterministic health + latency target |
| Institutional | causal feature tests | live comparison against MT5 bars | no future-data leakage |
| Technical | indicator range tests | multi-timeframe live verification | all configured symbols pass |
| Regime | regime output tests | trending/ranging/volatile sessions observed | stable regime telemetry |
| Fusion | score/confidence tests | disagreement/HOLD scenarios observed | no bypass of hard flip/guards |
| Confidence | threshold tests | live distribution reviewed | thresholds signed off |
| Thesis | BUY/SELL/HOLD invariants | thesis persistence/re-arm continuity verified | no stale resurrection |
| Risk | daily loss/spread/stale/DD tests | broker edge cases reproduced | every guard blocks correctly |
| Capital | risk-to-volume tests | broker min/step/tick-value verified | no over-budget lot |
| Equity Router | boundary + sticky-lock tests | live equity crosses tier boundaries while flat/open | no mid-position engine switch |
| Flipper | engine/profile tests | demo order lifecycle | open/manage/close PASS |
| Scalper | engine/profile tests | demo order lifecycle | open/manage/close PASS |
| Master | engine/profile tests | demo order lifecycle | open/manage/close PASS |
| MT5 Gateway | API/idempotency/opposite-position tests | MetaEditor/terminal + broker demo | retcodes/reconnect/requotes PASS |
| Broker | dry-run contract | real broker demo and low-risk live certification | order/deal reconciliation PASS |
| Managed | management API tests | BE/trailing/freeze/stops behavior | no invalid/worsening SL |
| Closed | close endpoint tests | manual + automated close | terminal and history agree |
| Database | schema/auth tests | backup/restore drill | successful restore evidence |
| Admin | authenticated endpoints | operator acceptance | required controls/visibility PASS |
| Mobile | API contract + source build | signed Android/iOS release builds | install/login/dashboard PASS |
| Billing/Licensing | state transition tests | provider webhook/production credentials | end-to-end paid→licensed PASS |
| Notifications | queue/API test | push provider credentials/device receipt | delivery evidence |
| Security | JWT/password/RBAC tests | TLS/domain/firewall/secret rotation | security checklist PASS |

## Release rule

The platform may be labelled **100% Production Released** only after every row is PASS. Until then, the release status must state exactly which external gates remain.
