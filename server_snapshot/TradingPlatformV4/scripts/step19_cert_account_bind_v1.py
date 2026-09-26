from __future__ import annotations

import argparse
import secrets
import sys
import time
from pathlib import Path

from sqlalchemy import select

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as mt5

from abutron.config import settings as core_settings
from abutron.platform_db import (
    User,
    TradingAccount,
    License,
    AuditEvent,
    session_scope,
)
from abutron.security import hash_password
from abutron.service import TradingService
from abutron.profiles import route_equity
from mt5_bridge.settings import settings as bridge_settings


BUILD_MARKER = "STEP19_CERT_ACCOUNT_BINDER_V1"
CERT_EMAIL = "step19-certification@abutron.local"
CERT_NAME = "ABUTRON STEP 19 CERTIFICATION"
CERT_ACTOR = "step19-certification"


def emit(key: str, value) -> None:
    print(f"{key}={value}", flush=True)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def mask_login(login: str) -> str:
    login = str(login or "")
    if len(login) <= 4:
        return "*" * len(login)
    return "*" * (len(login) - 4) + login[-4:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--cert-login",
        required=True,
    )
    parser.add_argument(
        "--require-tier",
        choices=("SCALPER", "MASTER"),
        required=True,
    )
    parser.add_argument(
        "--mt5-path",
        required=True,
    )
    parser.add_argument(
        "--license-hours",
        type=int,
        default=72,
    )
    args = parser.parse_args()

    cert_login = str(args.cert_login).strip()
    require(cert_login.isdigit(), "CERT_LOGIN_INVALID")
    require(1 <= int(args.license_hours) <= 168, "LICENSE_HOURS_OUT_OF_RANGE")

    emit("BUILD_MARKER", BUILD_MARKER)
    emit("CERT_LOGIN", mask_login(cert_login))
    emit("REQUIRED_TIER", args.require_tier)

    # Production safety must stay locked while we touch only account/license metadata.
    require(core_settings.execution_enabled is False, "ABUTRON_EXECUTION_ENABLED must remain false.")
    require(bridge_settings.live_trading is False, "MT5_LIVE_TRADING must remain false.")
    require(bridge_settings.management_enabled is False, "MT5_MANAGEMENT_ENABLED must remain false.")
    require(bridge_settings.demo_only is True, "MT5_DEMO_ONLY must remain true.")

    emit("PRODUCTION_EXECUTION_LOCKS", "PASS")

    require(
        mt5.initialize(path=args.mt5_path),
        f"MT5_INIT_FAILED:{mt5.last_error()}",
    )

    try:
        info = mt5.account_info()
        require(info is not None, "MT5_ACCOUNT_INFO_UNAVAILABLE")

        actual_login = str(getattr(info, "login", "") or "").strip()
        actual_server = str(getattr(info, "server", "") or "").strip()
        actual_equity = float(getattr(info, "equity", 0.0) or 0.0)
        actual_trade_mode = int(getattr(info, "trade_mode", -1))

        expected_server = str(bridge_settings.expected_server or "").strip()
        require(bool(expected_server), "MT5_EXPECTED_SERVER_REQUIRED")

        require(
            actual_login == cert_login,
            "CONNECTED_LOGIN_DOES_NOT_MATCH_CERT_LOGIN",
        )
        require(
            actual_server.casefold() == expected_server.casefold(),
            "CONNECTED_SERVER_DOES_NOT_MATCH_EXPECTED_SERVER",
        )
        require(
            actual_trade_mode == int(getattr(mt5, "ACCOUNT_TRADE_MODE_DEMO", 0)),
            "CONNECTED_ACCOUNT_IS_NOT_DEMO",
        )

        actual_tier = route_equity(actual_equity)
        require(
            actual_tier.value == args.require_tier,
            f"ACTUAL_EQUITY_ROUTES_TO_{actual_tier.value}_NOT_{args.require_tier}",
        )

        positions = mt5.positions_get()
        require(positions is not None, f"POSITIONS_GET_FAILED:{mt5.last_error()}")
        orders = mt5.orders_get()
        require(orders is not None, f"ORDERS_GET_FAILED:{mt5.last_error()}")

        require(len(positions) == 0, "CERT_ACCOUNT_MUST_HAVE_ZERO_OPEN_POSITIONS")
        require(len(orders) == 0, "CERT_ACCOUNT_MUST_HAVE_ZERO_PENDING_ORDERS")

        emit("CONNECTED_LOGIN_MATCH", "PASS")
        emit("CONNECTED_SERVER_MATCH", "PASS")
        emit("CONNECTED_ACCOUNT_DEMO", "PASS")
        emit("ACTUAL_EQUITY_TIER_MATCH", "PASS")
        emit("ZERO_OPEN_POSITIONS", "PASS")
        emit("ZERO_PENDING_ORDERS", "PASS")

    finally:
        mt5.shutdown()

    now = int(time.time())
    expires_ts = now + int(args.license_hours) * 3600

    created_user = False
    created_account = False
    created_license = False
    renewed_license = False

    with session_scope() as s:
        # Refuse to touch an existing login bound to another server.
        same_login = list(
            s.scalars(
                select(TradingAccount)
                .where(TradingAccount.login == cert_login)
                .order_by(TradingAccount.id.asc())
            ).all()
        )

        exact = [
            row for row in same_login
            if str(row.server or "").strip().casefold()
            == actual_server.casefold()
        ]

        wrong_server = [
            row for row in same_login
            if str(row.server or "").strip()
            and str(row.server or "").strip().casefold()
            != actual_server.casefold()
        ]

        require(
            not wrong_server,
            "CERT_LOGIN_ALREADY_BOUND_TO_DIFFERENT_SERVER",
        )
        require(
            len(exact) <= 1,
            "CERT_TRADING_ACCOUNT_AMBIGUOUS",
        )

        cert_user = s.scalar(
            select(User)
            .where(User.email == CERT_EMAIL)
        )

        if cert_user is None:
            cert_user = User(
                email=CERT_EMAIL,
                full_name=CERT_NAME,
                phone="",
                password_hash=hash_password(secrets.token_urlsafe(48)),
                role="customer",
                active=True,
            )
            s.add(cert_user)
            s.flush()
            created_user = True
        else:
            require(
                str(cert_user.full_name or "") == CERT_NAME,
                "CERT_EMAIL_ALREADY_USED_BY_NON_CERTIFICATION_USER",
            )
            require(
                bool(cert_user.active) is True,
                "CERTIFICATION_USER_IS_INACTIVE",
            )

        if exact:
            account = exact[0]

            # Never silently hijack a real/customer account.
            require(
                int(account.user_id) == int(cert_user.id),
                "EXISTING_CERT_LOGIN_BELONGS_TO_DIFFERENT_USER",
            )
            require(
                bool(account.active) is True,
                "EXISTING_CERT_ACCOUNT_IS_INACTIVE",
            )
        else:
            account = TradingAccount(
                user_id=cert_user.id,
                broker="IC Markets",
                login=cert_login,
                server=actual_server,
                symbol="XAUUSD",
                current_tier="",
                active=True,
            )
            s.add(account)
            s.flush()
            created_account = True

        latest_license = s.scalar(
            select(License)
            .where(License.user_id == cert_user.id)
            .order_by(License.id.desc())
        )

        if latest_license is None:
            latest_license = License(
                user_id=cert_user.id,
                product="ABUTRON_V4",
                status="active",
                expires_ts=expires_ts,
            )
            s.add(latest_license)
            s.flush()
            created_license = True
        else:
            # Dedicated certification user only; safe to renew/activate.
            latest_license.product = "ABUTRON_V4"
            latest_license.status = "active"
            latest_license.expires_ts = expires_ts
            renewed_license = True

        s.add(
            AuditEvent(
                actor=CERT_ACTOR,
                action="STEP19_CERT_ACCOUNT_BOUND",
                subject=mask_login(cert_login),
                detail=(
                    f"tier={args.require_tier};"
                    f"server={actual_server};"
                    f"license_expires_ts={expires_ts}"
                ),
            )
        )

    require(
        TradingService._platform_license_for_login(cert_login) is True,
        "PLATFORM_LICENSE_STILL_INACTIVE_AFTER_BIND",
    )

    emit("CERT_USER_CREATED", created_user)
    emit("CERT_ACCOUNT_CREATED", created_account)
    emit("CERT_LICENSE_CREATED", created_license)
    emit("CERT_LICENSE_RENEWED", renewed_license)
    emit("EXACT_PLATFORM_ACCOUNT_BINDING", "PASS")
    emit("PLATFORM_LICENSE_ACTIVE", "PASS")
    emit("LICENSE_DURATION_HOURS", int(args.license_hours))
    emit("PRODUCTION_ENV_CHANGED", False)
    emit("TRADING_CORE_SOURCE_CHANGED", False)
    emit("DEMO_ORDER_SENT", False)
    emit("STEP19_CERT_ACCOUNT_BIND", "PASS")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
