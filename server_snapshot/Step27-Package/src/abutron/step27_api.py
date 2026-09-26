from __future__ import annotations

import json
import secrets
import time
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from abutron import __version__
from abutron.config import settings
from abutron.platform_db import (
    License,
    Subscription,
    User,
    audit,
    session_scope,
)
from abutron.security import current_user, require_admin
from abutron.step26a_models import DeviceRegistration, SupportTicket
from abutron.step27_models import (
    BillingInvoice,
    CRMNote,
    CRMProfile,
    CRMTask,
    LicenseGrant,
    NotificationOutbox,
    NotificationPreference,
    PaymentEvent,
)
from abutron.step27_service import (
    approve_license_grant,
    dispatch_outbox_row,
    notification_preference,
    payload_digest,
    verify_hmac,
    webhook_enabled,
)


router = APIRouter(tags=["Step 27"])


class CRMProfilePatch(BaseModel):
    lifecycle_stage: Literal["lead", "onboarding", "customer", "vip", "at_risk", "inactive"] | None = None
    lead_source: str | None = Field(default=None, max_length=128)
    broker_partner: str | None = Field(default=None, max_length=128)
    country: str | None = Field(default=None, max_length=64)
    assigned_to: str | None = Field(default=None, max_length=255)
    tags: list[str] | None = None
    mark_contacted: bool = False


class CRMNoteBody(BaseModel):
    body: str = Field(min_length=1, max_length=10000)


class CRMTaskBody(BaseModel):
    title: str = Field(min_length=2, max_length=255)
    detail: str = Field(default="", max_length=10000)
    priority: Literal["low", "normal", "high", "urgent"] = "normal"
    due_ts: int | None = None
    assigned_to: str = Field(default="", max_length=255)


class CRMTaskPatch(BaseModel):
    status: Literal["open", "in_progress", "done", "cancelled"] | None = None
    priority: Literal["low", "normal", "high", "urgent"] | None = None
    due_ts: int | None = None
    assigned_to: str | None = Field(default=None, max_length=255)


class InvoiceCreateBody(BaseModel):
    user_id: int
    plan: str = Field(min_length=1, max_length=64)
    product: str = Field(default="ABUTRON_V4", max_length=64)
    currency: str = Field(default="ZAR", min_length=3, max_length=8)
    amount_minor: int = Field(gt=0)
    status: Literal["draft", "issued", "pending"] = "issued"
    provider: str = Field(default="manual", max_length=64)
    provider_ref: str = Field(default="", max_length=255)
    notes: str = Field(default="", max_length=10000)
    due_ts: int | None = None


class InvoicePatchBody(BaseModel):
    status: Literal["draft", "issued", "pending", "paid", "void", "refunded"] | None = None
    provider_ref: str | None = Field(default=None, max_length=255)
    notes: str | None = Field(default=None, max_length=10000)
    due_ts: int | None = None


class PaymentRecordBody(BaseModel):
    event_id: str = Field(min_length=3, max_length=255)
    amount_minor: int = Field(gt=0)
    currency: str = Field(min_length=3, max_length=8)
    provider: str = Field(default="manual", max_length=64)
    provider_ref: str = Field(default="", max_length=255)


class LicenseGrantCreateBody(BaseModel):
    user_id: int
    invoice_id: int | None = None
    product: str = Field(default="ABUTRON_V4", max_length=64)


class LicenseApproveBody(BaseModel):
    expires_ts: int | None = None


class NotificationPreferencePatch(BaseModel):
    in_app_enabled: bool | None = None
    email_enabled: bool | None = None
    push_enabled: bool | None = None
    billing_enabled: bool | None = None
    support_enabled: bool | None = None
    marketing_enabled: bool | None = None


class NotificationCreateBody(BaseModel):
    user_id: int | None = None
    channels: list[Literal["in_app", "email", "push"]] = Field(min_length=1)
    category: Literal["service", "billing", "support", "security", "marketing"] = "service"
    title: str = Field(min_length=1, max_length=255)
    body: str = Field(min_length=1, max_length=10000)
    dedupe_prefix: str = Field(default="", max_length=128)


def _crm_profile(session, user_id: int) -> CRMProfile:
    row = session.scalar(select(CRMProfile).where(CRMProfile.user_id == user_id))
    if row is None:
        row = CRMProfile(user_id=user_id)
        session.add(row)
        session.flush()
    return row


def _json_tags(raw: str) -> list[str]:
    try:
        value = json.loads(raw or "[]")
        return [str(x) for x in value] if isinstance(value, list) else []
    except Exception:
        return []


def _invoice_payload(x: BillingInvoice) -> dict:
    return {
        "id": x.id,
        "invoice_number": x.invoice_number,
        "user_id": x.user_id,
        "plan": x.plan,
        "product": x.product,
        "currency": x.currency,
        "amount_minor": x.amount_minor,
        "status": x.status,
        "provider": x.provider,
        "provider_ref": x.provider_ref,
        "notes": x.notes,
        "due_ts": x.due_ts,
        "paid_ts": x.paid_ts,
        "created_ts": x.created_ts,
        "updated_ts": x.updated_ts,
    }


def _crm_payload(x: CRMProfile) -> dict:
    return {
        "user_id": x.user_id,
        "lifecycle_stage": x.lifecycle_stage,
        "lead_source": x.lead_source,
        "broker_partner": x.broker_partner,
        "country": x.country,
        "assigned_to": x.assigned_to,
        "tags": _json_tags(x.tags_json),
        "last_contact_ts": x.last_contact_ts,
        "created_ts": x.created_ts,
        "updated_ts": x.updated_ts,
    }


@router.get("/v1/customer/operations")
def customer_operations(user=Depends(current_user)):
    now = int(time.time())
    with session_scope() as s:
        crm = _crm_profile(s, user.id)
        invoices = s.scalars(
            select(BillingInvoice)
            .where(BillingInvoice.user_id == user.id)
            .order_by(BillingInvoice.id.desc())
            .limit(20)
        ).all()
        grants = s.scalars(
            select(LicenseGrant)
            .where(LicenseGrant.user_id == user.id)
            .order_by(LicenseGrant.id.desc())
            .limit(20)
        ).all()
        tasks_open = s.scalar(
            select(func.count())
            .select_from(CRMTask)
            .where(
                CRMTask.user_id == user.id,
                CRMTask.status.in_(["open", "in_progress"]),
            )
        ) or 0
        support_open = s.scalar(
            select(func.count())
            .select_from(SupportTicket)
            .where(
                SupportTicket.user_id == user.id,
                SupportTicket.status.in_(["open", "in_progress"]),
            )
        ) or 0
        pref = notification_preference(s, user.id)

    return {
        "step": "27",
        "version": __version__,
        "execution_enabled": bool(settings.execution_enabled),
        "live_money_authorized": False,
        "billing_provider_certified": False,
        "email_provider_certified": False,
        "push_provider_certified": False,
        "crm": _crm_payload(crm),
        "invoices": [_invoice_payload(x) for x in invoices],
        "license_grants": [
            {
                "id": x.id,
                "invoice_id": x.invoice_id,
                "license_id": x.license_id,
                "product": x.product,
                "status": x.status,
                "approved_ts": x.approved_ts,
            }
            for x in grants
        ],
        "operations": {
            "open_crm_tasks": tasks_open,
            "open_support_tickets": support_open,
        },
        "notification_preferences": {
            "in_app_enabled": pref.in_app_enabled,
            "email_enabled": pref.email_enabled,
            "push_enabled": pref.push_enabled,
            "billing_enabled": pref.billing_enabled,
            "support_enabled": pref.support_enabled,
            "marketing_enabled": pref.marketing_enabled,
        },
    }


@router.get("/v1/customer/billing/invoices")
def customer_invoices(limit: int = 100, user=Depends(current_user)):
    limit = max(1, min(limit, 500))
    with session_scope() as s:
        rows = s.scalars(
            select(BillingInvoice)
            .where(BillingInvoice.user_id == user.id)
            .order_by(BillingInvoice.id.desc())
            .limit(limit)
        ).all()
    return [_invoice_payload(x) for x in rows]


@router.get("/v1/customer/billing/invoices/{invoice_id}")
def customer_invoice(invoice_id: int, user=Depends(current_user)):
    with session_scope() as s:
        row = s.get(BillingInvoice, invoice_id)
        if row is None or row.user_id != user.id:
            raise HTTPException(404, "Invoice not found")
        return _invoice_payload(row)


@router.get("/v1/customer/notification-preferences")
def customer_notification_preferences(user=Depends(current_user)):
    with session_scope() as s:
        row = notification_preference(s, user.id)
        return {
            "in_app_enabled": row.in_app_enabled,
            "email_enabled": row.email_enabled,
            "push_enabled": row.push_enabled,
            "billing_enabled": row.billing_enabled,
            "support_enabled": row.support_enabled,
            "marketing_enabled": row.marketing_enabled,
        }


@router.patch("/v1/customer/notification-preferences")
def patch_customer_notification_preferences(
    body: NotificationPreferencePatch,
    user=Depends(current_user),
):
    with session_scope() as s:
        row = notification_preference(s, user.id)
        for name in (
            "in_app_enabled",
            "email_enabled",
            "push_enabled",
            "billing_enabled",
            "support_enabled",
            "marketing_enabled",
        ):
            value = getattr(body, name)
            if value is not None:
                setattr(row, name, value)
        row.updated_ts = int(time.time())
    audit("STEP27_NOTIFICATION_PREFERENCES_UPDATED", str(user.id), actor=user.email)
    return {"updated": True}


@router.get("/v1/admin/crm/customers")
def admin_crm_customers(
    lifecycle_stage: str | None = None,
    limit: int = 500,
    admin=Depends(require_admin),
):
    limit = max(1, min(limit, 2000))
    with session_scope() as s:
        stmt = select(User, CRMProfile).outerjoin(CRMProfile, CRMProfile.user_id == User.id)
        if lifecycle_stage:
            stmt = stmt.where(CRMProfile.lifecycle_stage == lifecycle_stage)
        rows = s.execute(stmt.order_by(User.id.desc()).limit(limit)).all()
    return [
        {
            "user": {
                "id": u.id,
                "email": u.email,
                "full_name": u.full_name,
                "phone": u.phone,
                "active": u.active,
                "created_ts": u.created_ts,
            },
            "crm": _crm_payload(p) if p is not None else {
                "user_id": u.id,
                "lifecycle_stage": "customer",
                "lead_source": "",
                "broker_partner": "IC Markets",
                "country": "",
                "assigned_to": "",
                "tags": [],
                "last_contact_ts": None,
                "created_ts": None,
                "updated_ts": None,
            },
        }
        for u, p in rows
    ]


@router.get("/v1/admin/crm/customers/{user_id}")
def admin_crm_customer(user_id: int, admin=Depends(require_admin)):
    with session_scope() as s:
        u = s.get(User, user_id)
        if u is None:
            raise HTTPException(404, "User not found")
        crm = _crm_profile(s, user_id)
        notes = s.scalars(
            select(CRMNote).where(CRMNote.user_id == user_id).order_by(CRMNote.id.desc()).limit(100)
        ).all()
        tasks = s.scalars(
            select(CRMTask).where(CRMTask.user_id == user_id).order_by(CRMTask.id.desc()).limit(100)
        ).all()
        invoices = s.scalars(
            select(BillingInvoice)
            .where(BillingInvoice.user_id == user_id)
            .order_by(BillingInvoice.id.desc())
            .limit(100)
        ).all()
    return {
        "user": {
            "id": u.id,
            "email": u.email,
            "full_name": u.full_name,
            "phone": u.phone,
            "active": u.active,
            "created_ts": u.created_ts,
        },
        "crm": _crm_payload(crm),
        "notes": [
            {"id": x.id, "body": x.body, "created_by": x.created_by, "created_ts": x.created_ts}
            for x in notes
        ],
        "tasks": [
            {
                "id": x.id,
                "title": x.title,
                "detail": x.detail,
                "priority": x.priority,
                "status": x.status,
                "due_ts": x.due_ts,
                "assigned_to": x.assigned_to,
                "updated_ts": x.updated_ts,
            }
            for x in tasks
        ],
        "invoices": [_invoice_payload(x) for x in invoices],
    }


@router.patch("/v1/admin/crm/customers/{user_id}")
def patch_admin_crm_customer(
    user_id: int,
    body: CRMProfilePatch,
    admin=Depends(require_admin),
):
    with session_scope() as s:
        if s.get(User, user_id) is None:
            raise HTTPException(404, "User not found")
        row = _crm_profile(s, user_id)
        for name in ("lifecycle_stage", "lead_source", "broker_partner", "country", "assigned_to"):
            value = getattr(body, name)
            if value is not None:
                setattr(row, name, value.strip() if isinstance(value, str) else value)
        if body.tags is not None:
            row.tags_json = json.dumps(sorted({str(x).strip() for x in body.tags if str(x).strip()}))
        if body.mark_contacted:
            row.last_contact_ts = int(time.time())
        row.updated_ts = int(time.time())
    audit("STEP27_CRM_PROFILE_UPDATED", str(user_id), actor=admin.email)
    return {"updated": True, "user_id": user_id}


@router.post("/v1/admin/crm/customers/{user_id}/notes")
def add_admin_crm_note(
    user_id: int,
    body: CRMNoteBody,
    admin=Depends(require_admin),
):
    with session_scope() as s:
        if s.get(User, user_id) is None:
            raise HTTPException(404, "User not found")
        row = CRMNote(user_id=user_id, body=body.body.strip(), created_by=admin.email)
        s.add(row)
        s.flush()
        note_id = row.id
    audit("STEP27_CRM_NOTE_CREATED", str(note_id), str(user_id), admin.email)
    return {"created": True, "id": note_id}


@router.post("/v1/admin/crm/customers/{user_id}/tasks")
def create_admin_crm_task(
    user_id: int,
    body: CRMTaskBody,
    admin=Depends(require_admin),
):
    with session_scope() as s:
        if s.get(User, user_id) is None:
            raise HTTPException(404, "User not found")
        row = CRMTask(
            user_id=user_id,
            title=body.title.strip(),
            detail=body.detail.strip(),
            priority=body.priority,
            due_ts=body.due_ts,
            assigned_to=body.assigned_to.strip(),
            created_by=admin.email,
        )
        s.add(row)
        s.flush()
        task_id = row.id
    audit("STEP27_CRM_TASK_CREATED", str(task_id), str(user_id), admin.email)
    return {"created": True, "id": task_id}


@router.patch("/v1/admin/crm/tasks/{task_id}")
def patch_admin_crm_task(
    task_id: int,
    body: CRMTaskPatch,
    admin=Depends(require_admin),
):
    with session_scope() as s:
        row = s.get(CRMTask, task_id)
        if row is None:
            raise HTTPException(404, "CRM task not found")
        if body.status is not None:
            row.status = body.status
        if body.priority is not None:
            row.priority = body.priority
        if body.due_ts is not None:
            row.due_ts = body.due_ts
        if body.assigned_to is not None:
            row.assigned_to = body.assigned_to.strip()
        row.updated_ts = int(time.time())
    audit("STEP27_CRM_TASK_UPDATED", str(task_id), actor=admin.email)
    return {"updated": True, "id": task_id}


@router.post("/v1/admin/billing/invoices")
def create_admin_invoice(body: InvoiceCreateBody, admin=Depends(require_admin)):
    now = int(time.time())
    with session_scope() as s:
        if s.get(User, body.user_id) is None:
            raise HTTPException(404, "User not found")
        invoice_number = f"ABU-{time.strftime('%Y%m%d')}-{secrets.token_hex(4).upper()}"
        row = BillingInvoice(
            invoice_number=invoice_number,
            user_id=body.user_id,
            plan=body.plan.strip(),
            product=body.product.strip(),
            currency=body.currency.strip().upper(),
            amount_minor=body.amount_minor,
            status=body.status,
            provider=body.provider.strip(),
            provider_ref=body.provider_ref.strip(),
            notes=body.notes.strip(),
            due_ts=body.due_ts,
            created_by=admin.email,
            created_ts=now,
            updated_ts=now,
        )
        s.add(row)
        s.flush()
        payload = _invoice_payload(row)
    audit("STEP27_INVOICE_CREATED", payload["invoice_number"], actor=admin.email)
    return payload


@router.get("/v1/admin/billing/invoices")
def admin_invoices(
    status: str | None = None,
    user_id: int | None = None,
    limit: int = 500,
    admin=Depends(require_admin),
):
    limit = max(1, min(limit, 2000))
    with session_scope() as s:
        stmt = select(BillingInvoice)
        if status:
            stmt = stmt.where(BillingInvoice.status == status)
        if user_id is not None:
            stmt = stmt.where(BillingInvoice.user_id == user_id)
        rows = s.scalars(stmt.order_by(BillingInvoice.id.desc()).limit(limit)).all()
    return [_invoice_payload(x) for x in rows]


@router.patch("/v1/admin/billing/invoices/{invoice_id}")
def patch_admin_invoice(
    invoice_id: int,
    body: InvoicePatchBody,
    admin=Depends(require_admin),
):
    with session_scope() as s:
        row = s.get(BillingInvoice, invoice_id)
        if row is None:
            raise HTTPException(404, "Invoice not found")
        if body.status is not None:
            row.status = body.status
            if body.status == "paid" and row.paid_ts is None:
                row.paid_ts = int(time.time())
        if body.provider_ref is not None:
            row.provider_ref = body.provider_ref.strip()
        if body.notes is not None:
            row.notes = body.notes.strip()
        if body.due_ts is not None:
            row.due_ts = body.due_ts
        row.updated_ts = int(time.time())
    audit("STEP27_INVOICE_UPDATED", str(invoice_id), actor=admin.email)
    return {"updated": True, "id": invoice_id}


@router.post("/v1/admin/billing/invoices/{invoice_id}/record-payment")
def record_admin_payment(
    invoice_id: int,
    body: PaymentRecordBody,
    admin=Depends(require_admin),
):
    now = int(time.time())
    with session_scope() as s:
        invoice = s.get(BillingInvoice, invoice_id)
        if invoice is None:
            raise HTTPException(404, "Invoice not found")
        if body.amount_minor != invoice.amount_minor:
            raise HTTPException(409, "Payment amount does not match invoice")
        if body.currency.strip().upper() != invoice.currency.upper():
            raise HTTPException(409, "Payment currency does not match invoice")
        existing = s.scalar(
            select(PaymentEvent).where(
                PaymentEvent.provider == body.provider,
                PaymentEvent.event_id == body.event_id,
            )
        )
        if existing is not None:
            return {"recorded": True, "idempotent": True, "payment_event_id": existing.id}

        event = PaymentEvent(
            invoice_id=invoice.id,
            provider=body.provider.strip(),
            event_id=body.event_id.strip(),
            event_type="payment_recorded_admin",
            amount_minor=body.amount_minor,
            currency=body.currency.strip().upper(),
            verified=True,
            payload_digest="manual-admin-entry",
        )
        s.add(event)
        invoice.status = "paid"
        invoice.provider = body.provider.strip()
        if body.provider_ref:
            invoice.provider_ref = body.provider_ref.strip()
        invoice.paid_ts = now
        invoice.updated_ts = now
        s.flush()
        event_id = event.id

    # Important safety boundary: payment does not approve a license and does not enable trading.
    audit("STEP27_PAYMENT_RECORDED", str(event_id), f"invoice={invoice_id}", admin.email)
    return {
        "recorded": True,
        "payment_event_id": event_id,
        "invoice_status": "paid",
        "license_auto_activated": False,
        "trading_execution_changed": False,
    }


@router.post("/v1/billing/webhook/generic")
async def generic_billing_webhook(
    request: Request,
    x_abutron_signature: str = Header(default=""),
):
    body = await request.body()
    if not webhook_enabled():
        raise HTTPException(503, "Step27 billing webhook is disabled")
    if not verify_hmac(body, x_abutron_signature):
        raise HTTPException(401, "Invalid billing webhook signature")
    try:
        payload = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(400, "Invalid JSON")

    provider = str(payload.get("provider", "generic"))[:64]
    event_id = str(payload.get("event_id", ""))[:255]
    invoice_number = str(payload.get("invoice_number", ""))[:64]
    event_type = str(payload.get("event_type", ""))[:64]
    amount_minor = int(payload.get("amount_minor", 0) or 0)
    currency = str(payload.get("currency", "")).upper()[:8]

    if not event_id or not invoice_number or not event_type:
        raise HTTPException(400, "event_id, invoice_number and event_type are required")

    now = int(time.time())
    with session_scope() as s:
        existing = s.scalar(
            select(PaymentEvent).where(
                PaymentEvent.provider == provider,
                PaymentEvent.event_id == event_id,
            )
        )
        if existing is not None:
            return {"accepted": True, "idempotent": True}

        invoice = s.scalar(
            select(BillingInvoice).where(BillingInvoice.invoice_number == invoice_number)
        )
        if invoice is None:
            raise HTTPException(404, "Invoice not found")

        verified_payment = (
            event_type in ("payment.succeeded", "payment.paid")
            and amount_minor == invoice.amount_minor
            and currency == invoice.currency.upper()
        )

        event = PaymentEvent(
            invoice_id=invoice.id,
            provider=provider,
            event_id=event_id,
            event_type=event_type,
            amount_minor=amount_minor,
            currency=currency,
            verified=verified_payment,
            payload_digest=payload_digest(body),
        )
        s.add(event)

        if verified_payment:
            invoice.status = "paid"
            invoice.provider = provider
            invoice.provider_ref = str(payload.get("provider_ref", ""))[:255]
            invoice.paid_ts = now
            invoice.updated_ts = now

    # Safety boundary: webhook never creates/activates a License.
    return {
        "accepted": True,
        "payment_verified": verified_payment,
        "license_auto_activated": False,
        "trading_execution_changed": False,
    }


@router.post("/v1/admin/licenses/grants")
def create_license_grant(body: LicenseGrantCreateBody, admin=Depends(require_admin)):
    with session_scope() as s:
        if s.get(User, body.user_id) is None:
            raise HTTPException(404, "User not found")
        if body.invoice_id is not None:
            invoice = s.get(BillingInvoice, body.invoice_id)
            if invoice is None or invoice.user_id != body.user_id:
                raise HTTPException(409, "Invoice does not belong to user")
        row = LicenseGrant(
            user_id=body.user_id,
            invoice_id=body.invoice_id,
            product=body.product.strip(),
            status="pending",
            requested_by=admin.email,
        )
        s.add(row)
        s.flush()
        grant_id = row.id
    audit("STEP27_LICENSE_GRANT_REQUESTED", str(grant_id), actor=admin.email)
    return {"created": True, "id": grant_id, "status": "pending"}


@router.post("/v1/admin/licenses/grants/{grant_id}/approve")
def approve_admin_license_grant(
    grant_id: int,
    body: LicenseApproveBody,
    admin=Depends(require_admin),
):
    result = approve_license_grant(grant_id, admin.email, body.expires_ts)
    if not result.get("ok"):
        reason = result.get("reason", "failed")
        if reason == "not_found":
            raise HTTPException(404, "License grant not found")
        if reason == "invoice_not_paid":
            raise HTTPException(409, "Invoice must be paid before license approval")
        raise HTTPException(409, reason)
    audit("STEP27_LICENSE_GRANT_APPROVED", str(grant_id), actor=admin.email)
    return {
        **result,
        "trading_execution_changed": False,
        "live_money_authorized": False,
    }


@router.post("/v1/admin/licenses/grants/{grant_id}/revoke")
def revoke_admin_license_grant(grant_id: int, admin=Depends(require_admin)):
    now = int(time.time())
    with session_scope() as s:
        grant = s.get(LicenseGrant, grant_id)
        if grant is None:
            raise HTTPException(404, "License grant not found")
        grant.status = "revoked"
        grant.revoked_ts = now
        grant.updated_ts = now
        if grant.license_id is not None:
            lic = s.get(License, grant.license_id)
            if lic is not None:
                lic.status = "revoked"
    audit("STEP27_LICENSE_GRANT_REVOKED", str(grant_id), actor=admin.email)
    return {
        "revoked": True,
        "trading_execution_changed": False,
        "live_money_authorized": False,
    }


@router.post("/v1/admin/notifications")
def create_admin_notification(
    body: NotificationCreateBody,
    admin=Depends(require_admin),
):
    if body.user_id is not None:
        with session_scope() as s:
            if s.get(User, body.user_id) is None:
                raise HTTPException(404, "User not found")

    now = int(time.time())
    created = []
    with session_scope() as s:
        for channel in sorted(set(body.channels)):
            prefix = body.dedupe_prefix.strip() or f"admin-{now}-{secrets.token_hex(4)}"
            dedupe_key = f"{prefix}:{body.user_id or 'broadcast'}:{channel}"
            existing = s.scalar(
                select(NotificationOutbox).where(NotificationOutbox.dedupe_key == dedupe_key)
            )
            if existing is not None:
                created.append({"id": existing.id, "channel": channel, "idempotent": True})
                continue
            row = NotificationOutbox(
                user_id=body.user_id,
                channel=channel,
                category=body.category,
                title=body.title.strip(),
                body=body.body.strip(),
                state="queued",
                dedupe_key=dedupe_key,
                created_by=admin.email,
            )
            s.add(row)
            s.flush()
            created.append({"id": row.id, "channel": channel, "idempotent": False})
    audit("STEP27_NOTIFICATION_QUEUED", ",".join(str(x["id"]) for x in created), actor=admin.email)
    return {"queued": created}


@router.get("/v1/admin/notifications/outbox")
def admin_notification_outbox(
    state: str | None = None,
    limit: int = 500,
    admin=Depends(require_admin),
):
    limit = max(1, min(limit, 2000))
    with session_scope() as s:
        stmt = select(NotificationOutbox)
        if state:
            stmt = stmt.where(NotificationOutbox.state == state)
        rows = s.scalars(stmt.order_by(NotificationOutbox.id.desc()).limit(limit)).all()
    return [
        {
            "id": x.id,
            "user_id": x.user_id,
            "channel": x.channel,
            "category": x.category,
            "title": x.title,
            "body": x.body,
            "state": x.state,
            "attempts": x.attempts,
            "last_error": x.last_error,
            "created_ts": x.created_ts,
            "updated_ts": x.updated_ts,
        }
        for x in rows
    ]


@router.post("/v1/admin/notifications/outbox/{outbox_id}/dispatch")
def dispatch_admin_notification(outbox_id: int, admin=Depends(require_admin)):
    result = dispatch_outbox_row(outbox_id)
    if not result.get("ok"):
        raise HTTPException(404, "Notification outbox row not found")
    audit("STEP27_NOTIFICATION_DISPATCH_ATTEMPT", str(outbox_id), result["state"], admin.email)
    return result


@router.get("/v1/admin/step27/summary")
def admin_step27_summary(admin=Depends(require_admin)):
    with session_scope() as s:
        crm_profiles = s.scalar(select(func.count()).select_from(CRMProfile)) or 0
        open_tasks = s.scalar(
            select(func.count()).select_from(CRMTask).where(
                CRMTask.status.in_(["open", "in_progress"])
            )
        ) or 0
        invoices = s.scalar(select(func.count()).select_from(BillingInvoice)) or 0
        unpaid = s.scalar(
            select(func.count()).select_from(BillingInvoice).where(
                BillingInvoice.status.in_(["issued", "pending"])
            )
        ) or 0
        paid = s.scalar(
            select(func.count()).select_from(BillingInvoice).where(BillingInvoice.status == "paid")
        ) or 0
        pending_grants = s.scalar(
            select(func.count()).select_from(LicenseGrant).where(LicenseGrant.status == "pending")
        ) or 0
        queued = s.scalar(
            select(func.count()).select_from(NotificationOutbox).where(
                NotificationOutbox.state == "queued"
            )
        ) or 0
        blocked = s.scalar(
            select(func.count()).select_from(NotificationOutbox).where(
                NotificationOutbox.state.like("blocked%")
            )
        ) or 0
        active_devices = s.scalar(
            select(func.count()).select_from(DeviceRegistration).where(DeviceRegistration.active.is_(True))
        ) or 0

    return {
        "step": "27",
        "version": __version__,
        "execution_enabled": bool(settings.execution_enabled),
        "live_money_authorized": False,
        "crm_profiles": crm_profiles,
        "open_crm_tasks": open_tasks,
        "invoices": invoices,
        "unpaid_invoices": unpaid,
        "paid_invoices": paid,
        "pending_license_grants": pending_grants,
        "notification_outbox_queued": queued,
        "notification_outbox_blocked": blocked,
        "active_devices": active_devices,
        "billing_webhook_enabled": webhook_enabled(),
        "payment_provider_certified": False,
        "email_provider_certified": False,
        "push_provider_certified": False,
    }


@router.get("/admin/step27", response_class=HTMLResponse, include_in_schema=False)
def step27_admin_page():
    path = Path(__file__).resolve().parent.parent / "admin" / "step27.html"
    if not path.exists():
        raise HTTPException(404, "Step 27 admin console not installed")
    return path.read_text(encoding="utf-8")
