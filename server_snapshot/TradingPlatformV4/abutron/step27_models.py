from __future__ import annotations

import time

from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from abutron.platform_db import Base


class CRMProfile(Base):
    __tablename__ = "step27_crm_profiles"
    __table_args__ = (UniqueConstraint("user_id", name="uq_step27_crm_profile_user"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    lifecycle_stage: Mapped[str] = mapped_column(String(32), default="customer", index=True)
    lead_source: Mapped[str] = mapped_column(String(128), default="")
    broker_partner: Mapped[str] = mapped_column(String(128), default="IC Markets")
    country: Mapped[str] = mapped_column(String(64), default="")
    assigned_to: Mapped[str] = mapped_column(String(255), default="")
    tags_json: Mapped[str] = mapped_column(Text, default="[]")
    last_contact_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class CRMNote(Base):
    __tablename__ = "step27_crm_notes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    body: Mapped[str] = mapped_column(Text)
    created_by: Mapped[str] = mapped_column(String(255), default="")
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class CRMTask(Base):
    __tablename__ = "step27_crm_tasks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    title: Mapped[str] = mapped_column(String(255))
    detail: Mapped[str] = mapped_column(Text, default="")
    priority: Mapped[str] = mapped_column(String(16), default="normal")
    status: Mapped[str] = mapped_column(String(32), default="open", index=True)
    due_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    assigned_to: Mapped[str] = mapped_column(String(255), default="")
    created_by: Mapped[str] = mapped_column(String(255), default="")
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class BillingInvoice(Base):
    __tablename__ = "step27_billing_invoices"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    invoice_number: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    plan: Mapped[str] = mapped_column(String(64), default="")
    product: Mapped[str] = mapped_column(String(64), default="ABUTRON_V4")
    currency: Mapped[str] = mapped_column(String(8), default="ZAR")
    amount_minor: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(32), default="draft", index=True)
    provider: Mapped[str] = mapped_column(String(64), default="manual")
    provider_ref: Mapped[str] = mapped_column(String(255), default="")
    notes: Mapped[str] = mapped_column(Text, default="")
    due_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    paid_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_by: Mapped[str] = mapped_column(String(255), default="")
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class PaymentEvent(Base):
    __tablename__ = "step27_payment_events"
    __table_args__ = (
        UniqueConstraint("provider", "event_id", name="uq_step27_payment_provider_event"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    invoice_id: Mapped[int | None] = mapped_column(
        ForeignKey("step27_billing_invoices.id"), nullable=True, index=True
    )
    provider: Mapped[str] = mapped_column(String(64), default="manual")
    event_id: Mapped[str] = mapped_column(String(255), index=True)
    event_type: Mapped[str] = mapped_column(String(64), default="")
    amount_minor: Mapped[int] = mapped_column(Integer, default=0)
    currency: Mapped[str] = mapped_column(String(8), default="")
    verified: Mapped[bool] = mapped_column(Boolean, default=False)
    payload_digest: Mapped[str] = mapped_column(String(128), default="")
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class LicenseGrant(Base):
    __tablename__ = "step27_license_grants"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    invoice_id: Mapped[int | None] = mapped_column(
        ForeignKey("step27_billing_invoices.id"), nullable=True, index=True
    )
    license_id: Mapped[int | None] = mapped_column(
        ForeignKey("licenses.id"), nullable=True, index=True
    )
    product: Mapped[str] = mapped_column(String(64), default="ABUTRON_V4")
    status: Mapped[str] = mapped_column(String(32), default="pending", index=True)
    requested_by: Mapped[str] = mapped_column(String(255), default="")
    approved_by: Mapped[str] = mapped_column(String(255), default="")
    approved_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    revoked_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class NotificationPreference(Base):
    __tablename__ = "step27_notification_preferences"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_step27_notification_preference_user"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    in_app_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    email_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    push_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    billing_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    support_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    marketing_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class NotificationOutbox(Base):
    __tablename__ = "step27_notification_outbox"
    __table_args__ = (
        UniqueConstraint("dedupe_key", name="uq_step27_notification_outbox_dedupe"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id"), nullable=True, index=True
    )
    channel: Mapped[str] = mapped_column(String(32), default="in_app", index=True)
    category: Mapped[str] = mapped_column(String(32), default="service", index=True)
    title: Mapped[str] = mapped_column(String(255))
    body: Mapped[str] = mapped_column(Text)
    state: Mapped[str] = mapped_column(String(32), default="queued", index=True)
    dedupe_key: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    provider_message_id: Mapped[str] = mapped_column(String(255), default="")
    last_error: Mapped[str] = mapped_column(Text, default="")
    next_attempt_ts: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_by: Mapped[str] = mapped_column(String(255), default="")
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
