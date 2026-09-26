# Meta / WhatsApp onboarding for Abutron Jarvis

## Stage A — Meta assets
1. Create or select the Abutron Meta Business Portfolio.
2. Create a Meta Developer app and add the WhatsApp product.
3. Create/select the WhatsApp Business Account (WABA).
4. Add a dedicated Abutron Jarvis business phone number.
5. Verify ownership of that number by SMS or voice.
6. Record Business ID, WABA ID and Phone Number ID.
7. Register the phone for Cloud API and set the required 6-digit two-step-verification PIN.
8. Create a System User token for production with only the required WhatsApp permissions.

## Stage B — Jarvis webhook
1. Publish a public HTTPS reverse-proxy route to:
   /webhooks/whatsapp
2. Keep the Jarvis API itself bound to localhost/private network.
3. Put a random META_WEBHOOK_VERIFY_TOKEN in .env.
4. Configure the same verify token in Meta.
5. Store META_APP_SECRET and validate X-Hub-Signature-256 on every POST.
6. Subscribe the app to the WABA and required webhook fields.

## Stage C — Messaging
1. Configure Hermes `hermes whatsapp-cloud`.
2. Allowlist Dave/operator WhatsApp ID.
3. Send a test message.
4. Reply to Jarvis from WhatsApp and verify webhook receipt/audit.
5. Test incident text, image/report and voice-note/TTS paths.

## Stage D — Calling
1. Confirm the WABA/phone number is eligible/provisioned for WhatsApp Business Calling.
2. Enable the calling capability in Meta for the business number.
3. Subscribe the webhook to calling events.
4. Select/configure the real-time media transport (WebRTC/SIP gateway).
5. Complete SDP/media signalling integration.
6. Test user-initiated call to Jarvis.
7. Test business-initiated call only under Meta's permission/eligibility rules.
8. Test audio, hangup, failure, retry and incident correlation.
9. Only then set WHATSAPP_CALLING_ENABLED=true.

## Jarvis escalation policy
INFO -> audit/dashboard
WARNING -> WhatsApp message
CRITICAL -> WhatsApp message + request call escalation
EMERGENCY -> WhatsApp message + request call escalation + repeat/escalation runbook

Calling does not bypass the Abutron Policy Engine.
