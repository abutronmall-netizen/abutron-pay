from __future__ import annotations

import hashlib
import hmac
import json
import os
import time
from typing import Iterable

from sqlalchemy import select

from abutron.platform_db import License, Notification, Subscription, session_scope
from abutron.step27_models import (
    BillingInvoice,
    LicenseGrant,
    NotificationOutbox,
    NotificationPreference,
)


def webhook_enabled() -> bool:
    return os.getenv("STEP27_BILLING_WEBHOOK_ENABLED", "false").strip().lower() == "true"


def webhook_secret() -> str:
    return os.getenv("STEP27_BILLING_WEBHOOK_SECRET", "").strip()


def verify_hmac(body: bytes, signature: str) -> bool:
    secret = webhook_secret()
    if not webhook_enabled() or not secret or secret.startswith("CHANGE_ME"):
        return False
    expected = "sha256=" + hmac.new(
        secret.encode("utf-8"), body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature or "")


def payload_digest(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def notification_provider_ready(channel: str) -> bool:
    if channel == "in_app":
        return True
    env_name = {
        "email": "STEP27_EMAIL_PROVIDER_ENABLED",
        "push": "STEP27_PUSH_PROVIDER_ENABLED",
    }.get(channel)
    return bool(env_name and os.getenv(env_name, "false").strip().lower() == "true")


def notification_preference(session, user_id: int) -> NotificationPreference:
    row = session.scalar(
        select(NotificationPreference).where(NotificationPreference.user_id == user_id)
    )
    if row is None:
        row = NotificationPreference(user_id=user_id)
        session.add(row)
        session.flush()
    return row


def channel_allowed(pref: NotificationPreference, channel: str, category: str) -> bool:
    if channel == "in_app" and not pref.in_app_enabled:
        return False
    if channel == "email" and not pref.email_enabled:
        return False
    if channel == "push" and not pref.push_enabled:
        return False
    if category == "billing" and not pref.billing_enabled:
        return False
    if category == "support" and not pref.support_enabled:
        return False
    if category == "marketing" and not pref.marketing_enabled:
        return False
    return True


def dispatch_outbox_row(outbox_id: int) -> dict:
    now = int(time.time())
    with session_scope() as s:
        row = s.get(NotificationOutbox, outbox_id)
        if row is None:
            return {"ok": False, "reason": "not_found"}

        row.attempts += 1
        row.updated_ts = now

        if row.user_id is not None:
            pref = notification_preference(s, row.user_id)
            if not channel_allowed(pref, row.channel, row.category):
                row.state = "suppressed"
                row.last_error = "Disabled by customer notification preference"
                return {"ok": True, "state": row.state}

        if row.channel == "in_app":
            s.add(
                Notification(
                    user_id=row.user_id,
                    title=row.title,
                    body=row.body,
                    channel="in_app",
                    state="sent",
                )
            )
            row.state = "sent"
            row.last_error = ""
            row.provider_message_id = "internal"
            return {"ok": True, "state": row.state}

        if not notification_provider_ready(row.channel):
            row.state = "blocked_provider_unconfigured"
            row.last_error = (
                f"{row.channel} provider is not enabled/certified. "
                "No external delivery was attempted."
            )
            return {"ok": True, "state": row.state}

        # External provider adapters are intentionally fail-closed in Step27 v1.0.0.
        # A later provider-specific adapter must set the provider_message_id only
        # after an actual delivery API acknowledgement.
        row.state = "blocked_provider_adapter_required"
        row.last_error = f"{row.channel} provider adapter not installed"
        return {"ok": True, "state": row.state}


def approve_license_grant(grant_id: int, admin_email: str, expires_ts: int | None = None) -> dict:
    now = int(time.time())
    with session_scope() as s:
        grant = s.get(LicenseGrant, grant_id)
        if grant is None:
            return {"ok": False, "reason": "not_found"}
        if grant.status == "approved":
            return {"ok": True, "license_id": grant.license_id, "already_approved": True}

        if grant.invoice_id is not None:
            invoice = s.get(BillingInvoice, grant.invoice_id)
            if invoice is None:
                return {"ok": False, "reason": "invoice_not_found"}
            if invoice.status != "paid":
                return {"ok": False, "reason": "invoice_not_paid"}

        lic = s.scalar(
            select(License)
            .where(License.user_id == grant.user_id, License.product == grant.product)
            .order_by(License.id.desc())
        )
        if lic is None:
            lic = License(
                user_id=grant.user_id,
                product=grant.product,
                status="active",
                expires_ts=expires_ts,
            )
            s.add(lic)
            s.flush()
        else:
            lic.status = "active"
            lic.expires_ts = expires_ts

        grant.status = "approved"
        grant.license_id = lic.id
        grant.approved_by = admin_email
        grant.approved_ts = now
        grant.updated_ts = now

        sub = s.scalar(
            select(Subscription)
            .where(Subscription.user_id == grant.user_id)
            .order_by(Subscription.id.desc())
        )
        if sub is not None:
            sub.status = "active"
            sub.updated_ts = now

        return {"ok": True, "license_id": lic.id, "already_approved": False}
