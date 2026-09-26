from __future__ import annotations

import sys
import time
from pathlib import Path

ROOT = Path(r"C:\Abutron\TradingPlatformV4")

if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import MetaTrader5 as mt5

from mt5_bridge.settings import settings


def emit(name, value):
    print(f"{name}={value}", flush=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def get_abutron_positions():
    rows = mt5.positions_get()

    if rows is None:
        raise RuntimeError(
            f"positions_get failed: {mt5.last_error()}"
        )

    return [
        p for p in rows
        if (
            int(getattr(p, "magic", 0) or 0)
            == int(settings.magic)
        )
        or (
            str(
                getattr(p, "comment", "") or ""
            ).upper().startswith("ABUTRON")
        )
    ]


def wait_ticket_closed(ticket, seconds=20):
    deadline = time.time() + seconds

    while time.time() < deadline:

        rows = mt5.positions_get(
            ticket=int(ticket)
        )

        if rows is None:
            raise RuntimeError(
                f"positions_get(ticket) failed: "
                f"{mt5.last_error()}"
            )

        if len(rows) == 0:
            return True

        time.sleep(0.5)

    return False


def filling_candidates():

    mapping = {
        "IOC": mt5.ORDER_FILLING_IOC,
        "FOK": mt5.ORDER_FILLING_FOK,
        "RETURN": mt5.ORDER_FILLING_RETURN,
    }

    configured = str(
        getattr(
            settings,
            "filling_mode",
            "IOC"
        )
        or "IOC"
    ).upper()

    ordered = []

    for name in (
        configured,
        "IOC",
        "FOK",
        "RETURN"
    ):
        if (
            name in mapping
            and name not in ordered
        ):
            ordered.append(name)

    return [
        (name, mapping[name])
        for name in ordered
    ]


def close_position(ticket):

    for cycle in range(1, 5):

        rows = mt5.positions_get(
            ticket=int(ticket)
        )

        if rows is None:
            raise RuntimeError(
                f"positions_get(ticket) failed: "
                f"{mt5.last_error()}"
            )

        if len(rows) == 0:
            return True

        require(
            len(rows) == 1,
            "Expected exactly one position "
            "for this ticket."
        )

        p = rows[0]

        owned = (
            int(
                getattr(
                    p,
                    "magic",
                    0
                )
                or 0
            )
            == int(settings.magic)
        ) or (
            str(
                getattr(
                    p,
                    "comment",
                    ""
                )
                or ""
            )
            .upper()
            .startswith("ABUTRON")
        )

        require(
            owned,
            "Refusing to close a position "
            "that is not Abutron-owned."
        )

        require(
            str(p.symbol)
            .upper()
            .startswith("XAUUSD"),
            "Refusing cleanup of a "
            "non-XAUUSD position."
        )

        tick = mt5.symbol_info_tick(
            p.symbol
        )

        require(
            tick is not None,
            "Current XAUUSD tick unavailable."
        )

        is_buy = (
            int(p.type)
            == int(
                mt5.POSITION_TYPE_BUY
            )
        )

        selected = None

        for (
            fill_name,
            fill_value
        ) in filling_candidates():

            request = {
                "action":
                    mt5.TRADE_ACTION_DEAL,

                "position":
                    int(p.ticket),

                "symbol":
                    p.symbol,

                "volume":
                    float(p.volume),

                "type":
                    (
                        mt5.ORDER_TYPE_SELL
                        if is_buy
                        else mt5.ORDER_TYPE_BUY
                    ),

                "price":
                    float(
                        tick.bid
                        if is_buy
                        else tick.ask
                    ),

                "deviation":
                    max(
                        int(
                            settings.deviation_points
                        ),
                        50
                    ),

                "magic":
                    int(settings.magic),

                "comment":
                    "ABUTRON S17 CLOSE",

                "type_time":
                    mt5.ORDER_TIME_GTC,

                "type_filling":
                    int(fill_value),
            }

            check = mt5.order_check(
                request
            )

            if check is None:

                emit(
                    f"CLOSE_CHECK_{fill_name}",
                    "NONE"
                )

                continue

            rc = int(
                getattr(
                    check,
                    "retcode",
                    -1
                )
            )

            comment = str(
                getattr(
                    check,
                    "comment",
                    ""
                )
                or ""
            )

            emit(
                f"CLOSE_CHECK_{fill_name}_RETCODE",
                rc
            )

            emit(
                f"CLOSE_CHECK_{fill_name}_COMMENT",
                comment.replace(
                    "\n",
                    " "
                )
            )

            if rc == 0:

                selected = (
                    fill_name,
                    request
                )

                break

        require(
            selected is not None,
            "No broker-accepted filling mode "
            "was found for closing."
        )

        fill_name, request = selected

        emit(
            "CLOSE_SELECTED_FILLING",
            fill_name
        )

        emit(
            "CLOSE_SEND_CYCLE",
            cycle
        )

        result = mt5.order_send(
            request
        )

        require(
            result is not None,
            f"close order_send returned None: "
            f"{mt5.last_error()}"
        )

        retcode = int(
            getattr(
                result,
                "retcode",
                -1
            )
        )

        comment = str(
            getattr(
                result,
                "comment",
                ""
            )
            or ""
        )

        emit(
            "CLOSE_SEND_RETCODE",
            retcode
        )

        emit(
            "CLOSE_SEND_COMMENT",
            comment.replace(
                "\n",
                " "
            )
        )

        if retcode in (
            int(
                mt5.TRADE_RETCODE_DONE
            ),
            int(
                mt5.TRADE_RETCODE_DONE_PARTIAL
            )
        ):

            if wait_ticket_closed(
                ticket,
                seconds=15
            ):
                return True

        time.sleep(1)

    return wait_ticket_closed(
        ticket,
        seconds=2
    )


def main():

    terminal_path = sys.argv[1]

    emit(
        "CLEANUP_MODE",
        "CLOSE_ONLY"
    )

    emit(
        "NEW_POSITION_ALLOWED",
        False
    )

    require(
        settings.demo_only is True,
        "MT5_DEMO_ONLY must remain true."
    )

    require(
        settings.live_trading is False,
        "Production MT5_LIVE_TRADING "
        "must remain false."
    )

    require(
        settings.management_enabled
        is False,
        "Production MT5_MANAGEMENT_ENABLED "
        "must remain false."
    )

    require(
        settings.expected_login
        is not None,
        "Expected login not configured."
    )

    require(
        bool(
            str(
                settings.expected_server
                or ""
            ).strip()
        ),
        "Expected server not configured."
    )

    if not mt5.initialize(
        path=terminal_path
    ):
        raise RuntimeError(
            f"MT5 initialize failed: "
            f"{mt5.last_error()}"
        )

    try:

        terminal = mt5.terminal_info()
        account = mt5.account_info()

        require(
            terminal is not None,
            "terminal_info unavailable."
        )

        require(
            account is not None,
            "account_info unavailable."
        )

        require(
            bool(
                terminal.connected
            ),
            "MT5 is not connected."
        )

        require(
            bool(
                terminal.trade_allowed
            ),
            "MT5 Algo Trading is OFF."
        )

        require(
            int(account.login)
            == int(
                settings.expected_login
            ),
            "MT5 login mismatch."
        )

        require(
            str(account.server)
            == str(
                settings.expected_server
            ),
            "MT5 server mismatch."
        )

        require(
            "DEMO"
            in str(
                account.server
            ).upper(),
            "Connected MT5 account "
            "is not DEMO."
        )

        emit(
            "DEMO_IDENTITY",
            "PASS"
        )

        emit(
            "ACCOUNT_LOGIN_PRINTED",
            False
        )

        positions = (
            get_abutron_positions()
        )

        emit(
            "ABUTRON_POSITION_COUNT_BEFORE",
            len(positions)
        )

        if len(positions) == 0:

            emit(
                "RESIDUAL_POSITION_ALREADY_CLOSED",
                True
            )

            emit(
                "ZERO_RESIDUAL_EXPOSURE",
                "PASS"
            )

            return 0

        require(
            len(positions) == 1,
            "Cleanup requires exactly "
            "one Abutron position."
        )

        position = positions[0]

        require(
            str(
                position.symbol
            )
            .upper()
            .startswith("XAUUSD"),
            "Residual position is not XAUUSD."
        )

        ticket = int(
            position.ticket
        )

        emit(
            "RESIDUAL_TICKET_DETECTED",
            True
        )

        emit(
            "RESIDUAL_SYMBOL",
            position.symbol
        )

        emit(
            "RESIDUAL_VOLUME",
            float(
                position.volume
            )
        )

        success = close_position(
            ticket
        )

        require(
            success,
            "Could not confirm residual "
            "position closure."
        )

        final_positions = (
            get_abutron_positions()
        )

        emit(
            "ABUTRON_POSITION_COUNT_AFTER",
            len(final_positions)
        )

        require(
            len(final_positions) == 0,
            "Residual Abutron exposure remains."
        )

        emit(
            "STEP17_RESIDUAL_CLEANUP",
            "PASS"
        )

        emit(
            "ZERO_RESIDUAL_EXPOSURE",
            "PASS"
        )

        return 0

    finally:

        mt5.shutdown()


try:
    raise SystemExit(
        main()
    )

except SystemExit:
    raise

except BaseException as exc:

    emit(
        "STEP17_RESIDUAL_CLEANUP",
        "FAILED"
    )

    emit(
        "CLEANUP_FAILURE_TYPE",
        type(exc).__name__
    )

    emit(
        "CLEANUP_FAILURE",
        str(exc)
    )

    raise SystemExit(2)
