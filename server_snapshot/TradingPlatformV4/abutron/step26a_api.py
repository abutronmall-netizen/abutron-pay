from __future__ import annotations

import time
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from abutron import __version__
from abutron.config import settings
from abutron.platform_db import (
    License,
    Notification,
    Subscription,
    TradeRecord,
    TradingAccount,
    User,
    audit,
    session_scope,
)
from abutron.security import current_user, require_admin
from abutron.step26a_models import (
    CustomerPreference,
    DeviceRegistration,
    NotificationReceipt,
    SupportTicket,
)


router = APIRouter(tags=["Step 26A"])


class ProfilePatch(BaseModel):
    full_name: str | None = Field(default=None, min_length=2, max_length=255)
    phone: str | None = Field(default=None, max_length=64)
    notifications_enabled: bool | None = None
    preferred_symbol: str | None = Field(default=None, min_length=3, max_length=32)


class DeviceBody(BaseModel):
    device_id: str = Field(min_length=4, max_length=255)
    platform: Literal["android", "ios"]
    push_token: str = Field(default="", max_length=1024)
    app_version: str = Field(default="", max_length=64)


class SupportTicketBody(BaseModel):
    subject: str = Field(min_length=3, max_length=255)
    message: str = Field(min_length=5, max_length=10000)
    priority: Literal["low", "normal", "high"] = "normal"


class SupportTicketAdminPatch(BaseModel):
    status: Literal["open", "in_progress", "resolved", "closed"]
    admin_note: str = Field(default="", max_length=10000)


def _latest(rows):
    return rows[0] if rows else None


def _preference(session, user_id: int) -> CustomerPreference:
    pref = session.scalar(
        select(CustomerPreference).where(CustomerPreference.user_id == user_id)
    )
    if pref is None:
        pref = CustomerPreference(user_id=user_id)
        session.add(pref)
        session.flush()
    return pref


def _account_payload(a: TradingAccount) -> dict:
    return {
        "id": a.id,
        "broker": a.broker,
        "login": a.login,
        "server": a.server,
        "symbol": a.symbol,
        "current_tier": a.current_tier,
        "active": a.active,
        # Equity is broker-synchronized data and is deliberately not invented here.
        "equity": None,
    }


def _license_payload(x: License | None) -> dict | None:
    if x is None:
        return None
    return {
        "id": x.id,
        "product": x.product,
        "status": x.status,
        "expires_ts": x.expires_ts,
    }


def _subscription_payload(x: Subscription | None) -> dict | None:
    if x is None:
        return None
    return {
        "id": x.id,
        "plan": x.plan,
        "status": x.status,
        "external_ref": x.external_ref,
        "updated_ts": x.updated_ts,
    }


def _trade_payload(x: TradeRecord) -> dict:
    return {
        "id": x.id,
        "account_id": x.account_id,
        "symbol": x.symbol,
        "side": x.side,
        "tier": x.tier,
        "state": x.state,
        "ticket": x.ticket,
        "volume": x.volume,
        "entry": x.entry,
        "sl": x.sl,
        "tp": x.tp,
        "profit": x.profit,
        "opened_ts": x.opened_ts,
        "closed_ts": x.closed_ts,
    }


@router.get("/v1/mobile/bootstrap")
def mobile_bootstrap(user=Depends(current_user)):
    with session_scope() as s:
        accounts = s.scalars(
            select(TradingAccount)
            .where(TradingAccount.user_id == user.id)
            .order_by(TradingAccount.id.asc())
        ).all()
        licenses = s.scalars(
            select(License)
            .where(License.user_id == user.id)
            .order_by(License.id.desc())
        ).all()
        subscriptions = s.scalars(
            select(Subscription)
            .where(Subscription.user_id == user.id)
            .order_by(Subscription.id.desc())
        ).all()
        notes = s.scalars(
            select(Notification)
            .where((Notification.user_id == user.id) | (Notification.user_id.is_(None)))
            .order_by(Notification.id.desc())
            .limit(50)
        ).all()
        read_ids = set(
            s.scalars(
                select(NotificationReceipt.notification_id).where(
                    NotificationReceipt.user_id == user.id
                )
            ).all()
        )
        pref = _preference(s, user.id)
        open_support = (
            s.scalar(
                select(func.count())
                .select_from(SupportTicket)
                .where(
                    SupportTicket.user_id == user.id,
                    SupportTicket.status.in_(["open", "in_progress"]),
                )
            )
            or 0
        )

        latest_license = _latest(licenses)
        latest_subscription = _latest(subscriptions)

        notifications = [
            {
                "id": n.id,
                "title": n.title,
                "body": n.body,
                "channel": n.channel,
                "state": n.state,
                "created_ts": n.created_ts,
                "read": n.id in read_ids,
            }
            for n in notes
        ]

    return {
        "platform": {
            "name": "Abutron Trading Platform",
            "version": __version__,
            "step": "26A",
            "execution_enabled": bool(settings.execution_enabled),
            "broker_execution_certified": False,
            "mobile_trading_mode": "READ_ONLY",
        },
        "user": {
            "id": user.id,
            "email": user.email,
            "full_name": user.full_name,
            "phone": user.phone,
            "role": user.role,
            "active": user.active,
        },
        "preferences": {
            "notifications_enabled": pref.notifications_enabled,
            "preferred_symbol": pref.preferred_symbol,
        },
        "accounts": [_account_payload(a) for a in accounts],
        "license": _license_payload(latest_license),
        "subscription": _subscription_payload(latest_subscription),
        "notifications": notifications,
        "support": {"open_count": open_support},
        "features": {
            "dashboard": True,
            "trades": True,
            "notifications": True,
            "support": True,
            "profile": True,
            "order_entry": False,
            "broker_link_oauth": False,
        },
    }


@router.get("/v1/customer/status")
def customer_status(user=Depends(current_user)):
    now = int(time.time())
    with session_scope() as s:
        lic = s.scalar(
            select(License)
            .where(License.user_id == user.id)
            .order_by(License.id.desc())
        )
        sub = s.scalar(
            select(Subscription)
            .where(Subscription.user_id == user.id)
            .order_by(Subscription.id.desc())
        )
        accounts = s.scalars(
            select(TradingAccount).where(TradingAccount.user_id == user.id)
        ).all()

    license_active = bool(
        lic
        and lic.status == "active"
        and (lic.expires_ts is None or int(lic.expires_ts) >= now)
    )
    return {
        "user_active": bool(user.active),
        "license_active": license_active,
        "subscription_status": sub.status if sub else None,
        "account_count": len(accounts),
        "assigned_tiers": sorted({a.current_tier for a in accounts if a.current_tier}),
        "execution_enabled": bool(settings.execution_enabled),
        "mobile_trading_mode": "READ_ONLY",
    }


@router.patch("/v1/customer/profile")
def update_profile(body: ProfilePatch, user=Depends(current_user)):
    with session_scope() as s:
        db_user = s.get(User, user.id)
        if db_user is None:
            raise HTTPException(404, "User not found")
        if body.full_name is not None:
            db_user.full_name = body.full_name.strip()
        if body.phone is not None:
            db_user.phone = body.phone.strip()

        pref = _preference(s, user.id)
        if body.notifications_enabled is not None:
            pref.notifications_enabled = body.notifications_enabled
        if body.preferred_symbol is not None:
            pref.preferred_symbol = body.preferred_symbol.strip().upper()
        pref.updated_ts = int(time.time())

    audit("CUSTOMER_PROFILE_UPDATED", str(user.id), actor=user.email)
    return {"updated": True}


@router.get("/v1/customer/accounts")
def customer_accounts(user=Depends(current_user)):
    with session_scope() as s:
        rows = s.scalars(
            select(TradingAccount)
            .where(TradingAccount.user_id == user.id)
            .order_by(TradingAccount.id.asc())
        ).all()
    return [_account_payload(x) for x in rows]


@router.get("/v1/customer/trades")
def customer_trades(limit: int = 100, user=Depends(current_user)):
    limit = max(1, min(limit, 500))
    with session_scope() as s:
        account_ids = [
            x.id
            for x in s.scalars(
                select(TradingAccount).where(TradingAccount.user_id == user.id)
            ).all()
        ]
        if not account_ids:
            return []
        rows = s.scalars(
            select(TradeRecord)
            .where(TradeRecord.account_id.in_(account_ids))
            .order_by(TradeRecord.id.desc())
            .limit(limit)
        ).all()
    return [_trade_payload(x) for x in rows]


@router.post("/v1/devices/register")
def register_device(body: DeviceBody, user=Depends(current_user)):
    now = int(time.time())
    with session_scope() as s:
        row = s.scalar(
            select(DeviceRegistration).where(
                DeviceRegistration.user_id == user.id,
                DeviceRegistration.device_id == body.device_id,
            )
        )
        if row is None:
            row = DeviceRegistration(
                user_id=user.id,
                device_id=body.device_id,
                platform=body.platform,
                push_token=body.push_token,
                app_version=body.app_version,
                active=True,
                last_seen_ts=now,
            )
            s.add(row)
            s.flush()
        else:
            row.platform = body.platform
            row.push_token = body.push_token
            row.app_version = body.app_version
            row.active = True
            row.last_seen_ts = now
        device_id = row.id
    audit("DEVICE_REGISTERED", str(device_id), body.platform, user.email)
    return {"registered": True, "id": device_id}


@router.get("/v1/devices")
def list_devices(user=Depends(current_user)):
    with session_scope() as s:
        rows = s.scalars(
            select(DeviceRegistration)
            .where(DeviceRegistration.user_id == user.id)
            .order_by(DeviceRegistration.id.desc())
        ).all()
    return [
        {
            "id": x.id,
            "device_id": x.device_id,
            "platform": x.platform,
            "app_version": x.app_version,
            "active": x.active,
            "last_seen_ts": x.last_seen_ts,
        }
        for x in rows
    ]


@router.delete("/v1/devices/{device_id}")
def revoke_device(device_id: int, user=Depends(current_user)):
    with session_scope() as s:
        row = s.scalar(
            select(DeviceRegistration).where(
                DeviceRegistration.id == device_id,
                DeviceRegistration.user_id == user.id,
            )
        )
        if row is None:
            raise HTTPException(404, "Device not found")
        row.active = False
        row.push_token = ""
        row.last_seen_ts = int(time.time())
    audit("DEVICE_REVOKED", str(device_id), actor=user.email)
    return {"revoked": True}


@router.get("/v1/notifications")
def notifications(limit: int = 100, user=Depends(current_user)):
    limit = max(1, min(limit, 500))
    with session_scope() as s:
        rows = s.scalars(
            select(Notification)
            .where((Notification.user_id == user.id) | (Notification.user_id.is_(None)))
            .order_by(Notification.id.desc())
            .limit(limit)
        ).all()
        read_ids = set(
            s.scalars(
                select(NotificationReceipt.notification_id).where(
                    NotificationReceipt.user_id == user.id
                )
            ).all()
        )
    return [
        {
            "id": n.id,
            "title": n.title,
            "body": n.body,
            "channel": n.channel,
            "state": n.state,
            "created_ts": n.created_ts,
            "read": n.id in read_ids,
        }
        for n in rows
    ]


@router.put("/v1/notifications/{notification_id}/read")
def mark_notification_read(notification_id: int, user=Depends(current_user)):
    with session_scope() as s:
        notification = s.get(Notification, notification_id)
        if notification is None or (
            notification.user_id is not None and notification.user_id != user.id
        ):
            raise HTTPException(404, "Notification not found")
        existing = s.scalar(
            select(NotificationReceipt).where(
                NotificationReceipt.user_id == user.id,
                NotificationReceipt.notification_id == notification_id,
            )
        )
        if existing is None:
            s.add(
                NotificationReceipt(
                    user_id=user.id,
                    notification_id=notification_id,
                    read_ts=int(time.time()),
                )
            )
    return {"read": True}


@router.post("/v1/support/tickets")
def create_support_ticket(body: SupportTicketBody, user=Depends(current_user)):
    with session_scope() as s:
        ticket = SupportTicket(
            user_id=user.id,
            subject=body.subject.strip(),
            message=body.message.strip(),
            priority=body.priority,
            status="open",
        )
        s.add(ticket)
        s.flush()
        ticket_id = ticket.id
    audit("SUPPORT_TICKET_CREATED", str(ticket_id), body.priority, user.email)
    return {"created": True, "id": ticket_id, "status": "open"}


@router.get("/v1/support/tickets")
def list_support_tickets(user=Depends(current_user)):
    with session_scope() as s:
        rows = s.scalars(
            select(SupportTicket)
            .where(SupportTicket.user_id == user.id)
            .order_by(SupportTicket.id.desc())
        ).all()
    return [
        {
            "id": x.id,
            "subject": x.subject,
            "message": x.message,
            "priority": x.priority,
            "status": x.status,
            "admin_note": x.admin_note if x.status in ("resolved", "closed") else "",
            "created_ts": x.created_ts,
            "updated_ts": x.updated_ts,
        }
        for x in rows
    ]


@router.get("/v1/admin/customers/{user_id}")
def admin_customer_detail(user_id: int, admin=Depends(require_admin)):
    with session_scope() as s:
        user = s.get(User, user_id)
        if user is None:
            raise HTTPException(404, "User not found")
        accounts = s.scalars(
            select(TradingAccount).where(TradingAccount.user_id == user_id)
        ).all()
        licenses = s.scalars(
            select(License)
            .where(License.user_id == user_id)
            .order_by(License.id.desc())
        ).all()
        subscriptions = s.scalars(
            select(Subscription)
            .where(Subscription.user_id == user_id)
            .order_by(Subscription.id.desc())
        ).all()
        devices = s.scalars(
            select(DeviceRegistration)
            .where(DeviceRegistration.user_id == user_id)
            .order_by(DeviceRegistration.id.desc())
        ).all()
        support = s.scalars(
            select(SupportTicket)
            .where(SupportTicket.user_id == user_id)
            .order_by(SupportTicket.id.desc())
        ).all()

    return {
        "user": {
            "id": user.id,
            "email": user.email,
            "full_name": user.full_name,
            "phone": user.phone,
            "role": user.role,
            "active": user.active,
            "created_ts": user.created_ts,
        },
        "accounts": [_account_payload(a) for a in accounts],
        "licenses": [_license_payload(x) for x in licenses],
        "subscriptions": [_subscription_payload(x) for x in subscriptions],
        "devices": [
            {
                "id": d.id,
                "device_id": d.device_id,
                "platform": d.platform,
                "app_version": d.app_version,
                "active": d.active,
                "last_seen_ts": d.last_seen_ts,
            }
            for d in devices
        ],
        "support": [
            {
                "id": t.id,
                "subject": t.subject,
                "priority": t.priority,
                "status": t.status,
                "created_ts": t.created_ts,
                "updated_ts": t.updated_ts,
            }
            for t in support
        ],
    }


@router.get("/v1/admin/support/tickets")
def admin_support_tickets(
    status: str | None = None,
    limit: int = 200,
    admin=Depends(require_admin),
):
    limit = max(1, min(limit, 1000))
    with session_scope() as s:
        stmt = select(SupportTicket)
        if status:
            stmt = stmt.where(SupportTicket.status == status)
        rows = s.scalars(
            stmt.order_by(SupportTicket.id.desc()).limit(limit)
        ).all()
        user_ids = {x.user_id for x in rows}
        users = {
            u.id: u
            for u in s.scalars(select(User).where(User.id.in_(user_ids))).all()
        } if user_ids else {}
    return [
        {
            "id": x.id,
            "user_id": x.user_id,
            "user_email": users[x.user_id].email if x.user_id in users else "",
            "subject": x.subject,
            "message": x.message,
            "priority": x.priority,
            "status": x.status,
            "admin_note": x.admin_note,
            "created_ts": x.created_ts,
            "updated_ts": x.updated_ts,
        }
        for x in rows
    ]


@router.put("/v1/admin/support/tickets/{ticket_id}")
def admin_update_support_ticket(
    ticket_id: int,
    body: SupportTicketAdminPatch,
    admin=Depends(require_admin),
):
    with session_scope() as s:
        row = s.get(SupportTicket, ticket_id)
        if row is None:
            raise HTTPException(404, "Support ticket not found")
        row.status = body.status
        row.admin_note = body.admin_note.strip()
        row.updated_ts = int(time.time())
    audit("SUPPORT_TICKET_UPDATED", str(ticket_id), body.status, admin.email)
    return {"updated": True, "id": ticket_id, "status": body.status}


@router.get("/v1/admin/step26a/summary")
def admin_step26a_summary(admin=Depends(require_admin)):
    with session_scope() as s:
        devices = s.scalar(select(func.count()).select_from(DeviceRegistration)) or 0
        active_devices = (
            s.scalar(
                select(func.count())
                .select_from(DeviceRegistration)
                .where(DeviceRegistration.active.is_(True))
            )
            or 0
        )
        support_open = (
            s.scalar(
                select(func.count())
                .select_from(SupportTicket)
                .where(SupportTicket.status.in_(["open", "in_progress"]))
            )
            or 0
        )
        unread_receipts = s.scalar(
            select(func.count()).select_from(NotificationReceipt)
        ) or 0

    return {
        "step": "26A",
        "version": __version__,
        "mobile_trading_mode": "READ_ONLY",
        "execution_enabled": bool(settings.execution_enabled),
        "devices": devices,
        "active_devices": active_devices,
        "open_support_tickets": support_open,
        "notification_read_receipts": unread_receipts,
    }


@router.get("/admin/step26a", response_class=HTMLResponse, include_in_schema=False)
def step26a_admin_page():
    path = Path(__file__).resolve().parent.parent / "admin" / "step26a.html"
    if not path.exists():
        raise HTTPException(404, "Step 26A admin console not installed")
    return path.read_text(encoding="utf-8")
