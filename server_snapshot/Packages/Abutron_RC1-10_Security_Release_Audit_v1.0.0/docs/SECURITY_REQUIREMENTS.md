# RC1-10 release requirements

A final PASS requires all of the following:

1. Core execution remains disabled.
2. MT5 live trading and management remain disabled.
3. RC1-08 remains healthy in OBSERVE_ONLY.
4. RC1-09 remains healthy in NOTIFY_ONLY with Telegram enabled.
5. WhatsApp may remain disabled/deferred.
6. Live secret files are access-restricted.
7. No live secret placeholder is detected.
8. Plaintext legacy `.env.before/.bak/.old/.copy` files have been DPAPI-quarantined.
9. The previously exposed cTrader/Spotware secret has been replaced/rotated and is no longer used.
10. Provider console/rescue access is verified.
11. A provider/off-host snapshot exists.
12. All Windows Firewall profiles are enabled and do not default inbound traffic to Allow.
13. Abutron internal/admin/monitoring ports remain loopback-only.
14. Public sensitive trading/admin/docs/health routes remain default-denied.
15. Public HTTPS certificate validation succeeds and has sufficient remaining lifetime.
16. RDP is enabled with NLA and a listener.
17. Clean reboot produces no Event 41/6008 after the pre-reboot certificate.
18. A real post-reboot RDP reconnect succeeds.
19. Critical code/config/scheduled-task hashes do not drift.
20. Local encrypted rollback/SQLite restore test passes.
21. The server remains stable through the configured RDP stability window before final certification.
22. The user attests that normal RDP login succeeded after the unattended window without first rebooting or using a provider-console hard reset.
