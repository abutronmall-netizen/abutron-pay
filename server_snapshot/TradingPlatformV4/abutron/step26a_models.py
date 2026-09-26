from __future__ import annotations

import time

from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from abutron.platform_db import Base


class DeviceRegistration(Base):
    __tablename__ = "step26a_devices"
    __table_args__ = (
        UniqueConstraint("user_id", "device_id", name="uq_step26a_device_user_device"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    device_id: Mapped[str] = mapped_column(String(255), index=True)
    platform: Mapped[str] = mapped_column(String(16), default="unknown")
    push_token: Mapped[str] = mapped_column(String(1024), default="")
    app_version: Mapped[str] = mapped_column(String(64), default="")
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    last_seen_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class NotificationReceipt(Base):
    __tablename__ = "step26a_notification_receipts"
    __table_args__ = (
        UniqueConstraint("user_id", "notification_id", name="uq_step26a_notification_receipt"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    notification_id: Mapped[int] = mapped_column(ForeignKey("notifications.id"), index=True)
    read_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class SupportTicket(Base):
    __tablename__ = "step26a_support_tickets"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    subject: Mapped[str] = mapped_column(String(255))
    message: Mapped[str] = mapped_column(Text)
    priority: Mapped[str] = mapped_column(String(16), default="normal")
    status: Mapped[str] = mapped_column(String(32), default="open", index=True)
    admin_note: Mapped[str] = mapped_column(Text, default="")
    created_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))


class CustomerPreference(Base):
    __tablename__ = "step26a_customer_preferences"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_step26a_customer_preference_user"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    notifications_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    preferred_symbol: Mapped[str] = mapped_column(String(32), default="XAUUSD")
    updated_ts: Mapped[int] = mapped_column(Integer, default=lambda: int(time.time()))
