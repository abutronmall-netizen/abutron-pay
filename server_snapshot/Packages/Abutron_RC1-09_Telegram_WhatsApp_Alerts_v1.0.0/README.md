# Abutron RC1-09 — Telegram + WhatsApp / Meta Alerts v1.0.0

Production candidate notification layer for RC1-08.

## Scope
- Incident OPEN alerts
- Incident RECOVERED alerts
- Human approval-request alerts
- Telegram transport
- WhatsApp Cloud API transport
- Deduplication
- rate limiting
- transport retry before provider acceptance
- SQLite delivery audit
- signed WhatsApp status webhooks
- reboot persistence

## Safety
RC1-09 is notification-only. It exposes no approve/reject/restart/trade commands and runs on 127.0.0.1:8789.

## Required order
1. Install
2. Configure Telegram
3. Test Telegram
4. Configure WhatsApp
5. Patch Caddy webhook route
6. Configure Meta callback/template
7. Test WhatsApp
8. Reboot
9. Run final certification
