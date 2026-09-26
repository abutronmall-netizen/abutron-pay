# v1.0.4 additional certification gates

- [ ] Deterministic tests pass before live copy
- [ ] `startup_grace_active=true` immediately after RC1-08 restart
- [ ] `jarvis_rc1_08_suppressed_failures_total` metric exposed
- [ ] Windows reboot completed
- [ ] Jarvis + Hermes healthy after reboot
- [ ] Kronos + MT5 healthy after reboot
- [ ] Prometheus + Grafana healthy after reboot
- [ ] No new CRITICAL boot incidents for `jarvis_api`, `kronos_health`, or `mt5_bridge_health`
- [ ] No stale pending approvals
- [ ] `RC1_08_CERTIFIED=True`

---

# RC1-08 certification
- [ ] Baseline healthy
- [ ] Local bind only 127.0.0.1:8788
- [ ] Unauthorized API returns 401
- [ ] Forced failure opens exactly one incident
- [ ] Repeated failure deduplicates
- [ ] Hermes diagnosis persisted or deterministic failure recorded
- [ ] Only allowlisted actions create approvals
- [ ] Approval executes nothing in OBSERVE_ONLY
- [ ] Two healthy checks recover incident
- [ ] SQLite and audit survive restart
- [ ] Scheduled task survives reboot
- [ ] Prometheus/Grafana show RC1-08 metrics
- [ ] No secrets in DB/logs/evidence

- [ ] No PENDING approval remains attached to a RECOVERED incident.
- [ ] `kronos_health` uses 127.0.0.1:8088 and `mt5_bridge_health` uses 127.0.0.1:8090.

- [ ] Prometheus runtime command line points to `C:\Abutron\Jarvis\observability\prometheus\prometheus.yml`.
- [ ] `jarvis_rc1_08` Prometheus target reaches `health=up`.
- [ ] No `PENDING` approval references a `RECOVERED` incident.
