from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

import mt5_bridge.app as gateway
from mt5_bridge.store import IdempotencyStore
import mt5_bridge.store as store_module


class FakeStore:
    def __init__(self):
        self.responses={}
        self.claimed=set()

    def get(self,key):
        return self.responses.get(key)

    def claim(self,key):
        if key in self.claimed:
            return False
        self.claimed.add(key)
        return True

    def release_claim(self,key):
        self.claimed.discard(key)

    def put(self,key,response):
        self.responses[key]=response

    def put_position(
        self,
        ticket,
        initial_r,
        tier,
        signal_key
    ):
        pass


class FakePlan:
    idempotency_key="TEST-ORDER-CHECK-REJECT"
    volume=0.01
    entry=100.0
    sl=90.0

    direction=SimpleNamespace(
        value="BUY"
    )

    tier=SimpleNamespace(
        value="FLIPPER"
    )

    def model_dump(self,mode="json"):
        return {
            "idempotency_key":
                self.idempotency_key,
            "volume":
                self.volume
        }


def test_rejected_order_check_never_calls_order_send(
    monkeypatch
):
    fake_store=FakeStore()

    send_calls={
        "count":0
    }

    class FakeMT5:
        TRADE_RETCODE_DONE=10009
        POSITION_TYPE_BUY=0

        @staticmethod
        def order_check(request):
            return SimpleNamespace(
                retcode=10016,
                comment="Invalid stops"
            )

        @staticmethod
        def order_send(request):
            send_calls["count"]+=1
            raise AssertionError(
                "order_send must never execute "
                "after failed order_check"
            )

        @staticmethod
        def last_error():
            return (1,"Success")

    monkeypatch.setattr(
        gateway,
        "store",
        fake_store
    )

    monkeypatch.setattr(
        gateway,
        "mt5",
        FakeMT5
    )

    monkeypatch.setattr(
        gateway,
        "auth",
        lambda authorization: None
    )

    monkeypatch.setattr(
        gateway,
        "ready",
        lambda: None
    )

    monkeypatch.setattr(
        gateway,
        "_require_demo_if_configured",
        lambda: None
    )

    monkeypatch.setattr(
        gateway.settings,
        "live_trading",
        True
    )

    info=SimpleNamespace(
        volume_min=0.01,
        volume_max=10.0,
        volume_step=0.01,
        trade_tick_size=0.01,
        trade_tick_value=0.01,
        trade_stops_level=0
    )

    monkeypatch.setattr(
        gateway,
        "_build_order_request",
        lambda plan: (
            "BTCUSD",
            True,
            {
                "symbol":"BTCUSD",
                "volume":0.01
            },
            info
        )
    )

    with pytest.raises(
        HTTPException
    ) as exc:

        gateway.order(
            FakePlan(),
            authorization=None
        )

    assert exc.value.status_code==409

    assert (
        send_calls["count"]
        == 0
    )

    saved=fake_store.get(
        FakePlan.idempotency_key
    )

    assert saved is not None

    assert (
        saved["mode"]
        == "ORDER_CHECK_REJECTED"
    )


def test_sqlite_claim_allows_only_one_owner(
    tmp_path,
    monkeypatch
):
    db_path=(
        tmp_path
        / "idempotency-test.db"
    )

    monkeypatch.setattr(
        store_module.settings,
        "idempotency_db",
        str(db_path)
    )

    stores=[
        IdempotencyStore()
        for _ in range(8)
    ]

    key="CONCURRENT-CLAIM-TEST"

    def attempt(i):
        return stores[
            i % len(stores)
        ].claim(key)

    with ThreadPoolExecutor(
        max_workers=16
    ) as pool:

        results=list(
            pool.map(
                attempt,
                range(32)
            )
        )

    assert sum(
        1 for x in results if x
    ) == 1

    assert any(
        s.claim_exists(key)
        is not None
        for s in stores
    )

    stores[0].release_claim(
        key
    )

    assert (
        stores[1].claim(key)
        is True
    )