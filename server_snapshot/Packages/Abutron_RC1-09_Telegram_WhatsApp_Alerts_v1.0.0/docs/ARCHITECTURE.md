# RC1-09 architecture

RC1-08 authenticated API
  -> read incidents + approvals
  -> state transition detector
  -> notification event
  -> dedupe
  -> per-channel delivery queue
  -> rate limit
  -> retry before provider acceptance
  -> Telegram / WhatsApp transports
  -> delivery audit database
  -> WhatsApp signed status webhook

Safety boundary:
- NOTIFY_ONLY
- no trade execution
- no restart actions
- no approval action endpoints
- no inbound chat commands
- WhatsApp POST webhook ignores incoming messages and processes only delivery statuses
- localhost bind 127.0.0.1:8789
