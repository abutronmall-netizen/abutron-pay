from types import SimpleNamespace

import pytest
from fastapi import HTTPException

import mt5_bridge.app as gateway


class FakeMT5:
    account = None

    @classmethod
    def account_info(cls):
        return cls.account


def configure(
    monkeypatch,
    *,
    login,
    server
):
    FakeMT5.account = SimpleNamespace(
        login=login,
        server=server
    )

    monkeypatch.setattr(
        gateway,
        "mt5",
        FakeMT5
    )

    monkeypatch.setattr(
        gateway,
        "ready",
        lambda: None
    )

    monkeypatch.setattr(
        gateway.settings,
        "demo_only",
        True
    )

    monkeypatch.setattr(
        gateway.settings,
        "expected_login",
        53054439
    )

    monkeypatch.setattr(
        gateway.settings,
        "expected_server",
        "ICMarketsSC-Demo"
    )


def test_exact_demo_account_is_allowed(
    monkeypatch
):
    configure(
        monkeypatch,
        login=53054439,
        server="ICMarketsSC-Demo"
    )

    account=(
        gateway
        ._require_demo_if_configured()
    )

    assert account.login==53054439

    assert (
        account.server
        == "ICMarketsSC-Demo"
    )


def test_wrong_login_is_blocked(
    monkeypatch
):
    configure(
        monkeypatch,
        login=99999999,
        server="ICMarketsSC-Demo"
    )

    with pytest.raises(
        HTTPException
    ) as exc:

        gateway._require_demo_if_configured()

    assert (
        exc.value.status_code
        == 403
    )

    assert (
        exc.value.detail["error"]
        == "MT5_EXPECTED_LOGIN_MISMATCH"
    )


def test_wrong_demo_server_is_blocked(
    monkeypatch
):
    configure(
        monkeypatch,
        login=53054439,
        server="AnotherBroker-Demo"
    )

    with pytest.raises(
        HTTPException
    ) as exc:

        gateway._require_demo_if_configured()

    assert (
        exc.value.status_code
        == 403
    )

    assert (
        exc.value.detail["error"]
        == "MT5_EXPECTED_SERVER_MISMATCH"
    )


def test_live_server_is_blocked_even_with_expected_login(
    monkeypatch
):
    configure(
        monkeypatch,
        login=53054439,
        server="ICMarketsSC-Live"
    )

    with pytest.raises(
        HTTPException
    ) as exc:

        gateway._require_demo_if_configured()

    assert (
        exc.value.status_code
        == 403
    )

    assert (
        exc.value.detail["error"]
        == "MT5_DEMO_ONLY_BLOCK"
    )