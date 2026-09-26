# ABUTRON JARVIS Production v1
Production AI SRE + engineering control plane for Abutron Kronos.

Stack:
- Pydantic AI: authoritative typed agent control plane
- Durable incident/release workflow state
- Hermes Agent: research/memory + official WhatsApp Cloud gateway
- OpenHands Software Agent SDK: coding worker, DEV workspace only
- Abutron deterministic Policy Engine: ALLOW / APPROVAL / DENY
- Hardened Kronos/Windows/MT5 tools
- Independent test/release gates
- Prometheus/Grafana observability

Windows layout:
C:\Abutron\Jarvis
C:\Abutron\Kronos          (production; AI read-only)
C:\Abutron\Kronos-Dev      (coding sandbox)
C:\Abutron\Kronos-Test     (test environment)

Start with JARVIS_MODE=OBSERVE_ONLY. No AI may autonomously alter trading logic, risk,
lot sizing, equity routing, broker credentials, balances, discretionary orders, or deploy
unreviewed code.
