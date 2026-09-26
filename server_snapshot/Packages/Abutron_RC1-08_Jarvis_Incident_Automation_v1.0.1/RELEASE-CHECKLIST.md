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
