import json
from contextlib import contextmanager
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import abutron.api as api
import abutron.worker as worker

from abutron.models import (
    BotTier,
    Direction,
    OrderPlan,
)

from abutron.platform_db import (
    Base,
    User,
    TradingAccount,
    TradeRecord,
)


@pytest.fixture
def db(monkeypatch):
    engine=create_engine(
        "sqlite+pysqlite:///:memory:",
        future=True,
        connect_args={
            "check_same_thread":False,
        },
        poolclass=StaticPool,
    )

    Base.metadata.create_all(
        engine
    )

    Session=sessionmaker(
        bind=engine,
        expire_on_commit=False,
        future=True,
    )

    @contextmanager
    def scope():
        s=Session()

        try:
            yield s
            s.commit()

        except Exception:
            s.rollback()
            raise

        finally:
            s.close()

    monkeypatch.setattr(
        worker,
        "session_scope",
        scope,
    )

    monkeypatch.setattr(
        api,
        "session_scope",
        scope,
    )

    return scope


def seed_user_account(
    scope,
    email,
    login,
    server="ICMarketsSC-Demo",
):
    with scope() as s:
        user=User(
            email=email,
            full_name=email,
            password_hash="test",
        )

        s.add(user)
        s.flush()

        account=TradingAccount(
            user_id=user.id,
            broker="IC Markets",
            login=str(login),
            server=server,
            symbol="BTCUSD",
            active=True,
        )

        s.add(account)
        s.flush()

        return (
            user.id,
            account.id,
        )


def fake_result(
    position_ticket=9001,
    signal="SIGNAL-1",
    volume=0.02,
):
    plan=OrderPlan(
        symbol="BTCUSD",
        direction=Direction.BUY,
        tier=BotTier.FLIPPER,
        strategy_profile=
            "flipper-v4-adaptive-directional",
        volume=volume,
        entry=100.0,
        sl=95.0,
        tp=105.0,
        risk_amount=1.0,
        confidence=99.0,
        idempotency_key=signal,
        thesis_reason="CERTIFICATION",
    )

    result=SimpleNamespace(
        execution={
            "accepted":True,
            "order":8001,
            "deal":7001,
            "position_ticket":
                position_ticket,
        },

        plan=plan,

        route=SimpleNamespace(
            selected=BotTier.FLIPPER,
            locked=False,
        ),

        symbol="BTCUSD",
    )

    result.model_dump=lambda mode="json":{
        "execution":
            result.execution,

        "plan":
            plan.model_dump(
                mode="json"
            ),
    }

    return result


def deal(
    ticket,
    position,
    *,
    entry,
    deal_type,
    volume,
    price,
    profit=0.0,
    commission=0.0,
    swap=0.0,
    fee=0.0,
    ts=1000,
    magic=None,
    comment="ABUTRON FLIPPER",
):
    if magic is None:
        magic=int(
            worker.mt5_settings.magic
        )

    return {
        "ticket":ticket,
        "position_id":position,
        "entry":entry,
        "type":deal_type,
        "symbol":"BTCUSD",
        "volume":volume,
        "price":price,
        "profit":profit,
        "commission":commission,
        "swap":swap,
        "fee":fee,
        "time":ts,
        "magic":magic,
        "comment":comment,
    }


def test_execution_attaches_to_exact_account(
    db
):
    seed_user_account(
        db,
        "one@example.com",
        "111",
    )

    _,target_account=(
        seed_user_account(
            db,
            "two@example.com",
            "222",
        )
    )

    worker.persist_execution(
        fake_result(),
        "222",
        "ICMarketsSC-Demo",
    )

    with db() as s:
        rows=list(
            s.scalars(
                select(
                    TradeRecord
                )
            ).all()
        )

        assert len(rows) == 1

        assert (
            rows[0].account_id
            == target_account
        )

        assert (
            rows[0].ticket
            == "9001"
        )


def test_single_record_open_close_and_duplicate_history(
    db
):
    seed_user_account(
        db,
        "owner@example.com",
        "222",
    )

    worker.persist_execution(
        fake_result(
            volume=0.02
        ),
        "222",
        "ICMarketsSC-Demo",
    )

    deals=[
        deal(
            1001,
            9001,
            entry=0,
            deal_type=0,
            volume=0.02,
            price=100.0,
            commission=-0.01,
            ts=1000,
        ),

        deal(
            1002,
            9001,
            entry=1,
            deal_type=1,
            volume=0.02,
            price=101.0,
            profit=2.00,
            commission=-0.01,
            ts=1100,
            comment="ABUTRON CLOSE",
        ),
    ]

    worker.sync_deals(
        deals,
        "222",
        "ICMarketsSC-Demo",
    )

    # Poll the same history again.
    worker.sync_deals(
        deals,
        "222",
        "ICMarketsSC-Demo",
    )

    with db() as s:
        rows=list(
            s.scalars(
                select(
                    TradeRecord
                )
            ).all()
        )

        assert len(rows) == 1

        row=rows[0]

        assert row.state == "CLOSED"
        assert row.ticket == "9001"

        assert row.opened_ts == 1000
        assert row.closed_ts == 1100

        assert row.profit == pytest.approx(
            1.98
        )

        payload=json.loads(
            row.payload
        )

        reconciliation=(
            payload[
                "reconciliation"
            ]
        )

        assert (
            reconciliation[
                "deal_count"
            ]
            == 2
        )


def test_partial_close_remains_open_until_fully_closed(
    db
):
    seed_user_account(
        db,
        "partial@example.com",
        "333",
    )

    worker.persist_execution(
        fake_result(
            position_ticket=9100,
            signal="PARTIAL",
            volume=0.02,
        ),
        "333",
        "ICMarketsSC-Demo",
    )

    first=[
        deal(
            2001,
            9100,
            entry=0,
            deal_type=0,
            volume=0.02,
            price=100.0,
            ts=2000,
        ),

        deal(
            2002,
            9100,
            entry=1,
            deal_type=1,
            volume=0.01,
            price=101.0,
            profit=1.0,
            ts=2100,
            comment="ABUTRON CLOSE",
        ),
    ]

    worker.sync_deals(
        first,
        "333",
        "ICMarketsSC-Demo",
    )

    with db() as s:
        row=s.scalar(
            select(
                TradeRecord
            )
        )

        assert (
            row.state
            == "OPENED"
        )

        assert (
            row.closed_ts
            is None
        )

    second=[
        deal(
            2003,
            9100,
            entry=1,
            deal_type=1,
            volume=0.01,
            price=102.0,
            profit=2.0,
            ts=2200,
            comment="ABUTRON CLOSE",
        )
    ]

    worker.sync_deals(
        second,
        "333",
        "ICMarketsSC-Demo",
    )

    with db() as s:
        row=s.scalar(
            select(
                TradeRecord
            )
        )

        assert (
            row.state
            == "CLOSED"
        )

        assert (
            row.closed_ts
            == 2200
        )

        assert (
            row.profit
            == pytest.approx(
                3.0
            )
        )


def test_non_abutron_deal_is_ignored(
    db
):
    seed_user_account(
        db,
        "manual@example.com",
        "444",
    )

    worker.sync_deals(
        [
            deal(
                3001,
                9300,
                entry=0,
                deal_type=0,
                volume=0.01,
                price=100.0,
                ts=3000,
                magic=123,
                comment="MANUAL TRADE",
            )
        ],
        "444",
        "ICMarketsSC-Demo",
    )

    with db() as s:
        count=len(
            list(
                s.scalars(
                    select(
                        TradeRecord
                    )
                ).all()
            )
        )

        assert count == 0


def test_mobile_trade_history_is_user_isolated(
    db
):
    user1,account1=(
        seed_user_account(
            db,
            "mobile1@example.com",
            "501",
        )
    )

    user2,account2=(
        seed_user_account(
            db,
            "mobile2@example.com",
            "502",
        )
    )

    with db() as s:
        s.add(
            TradeRecord(
                account_id=account1,
                symbol="BTCUSD",
                side="BUY",
                tier="FLIPPER",
                state="CLOSED",
                ticket="A",
            )
        )

        s.add(
            TradeRecord(
                account_id=account2,
                symbol="BTCUSD",
                side="SELL",
                tier="SCALPER",
                state="CLOSED",
                ticket="B",
            )
        )

    rows=api.mobile_trades(
        limit=100,
        user=SimpleNamespace(
            id=user1
        ),
    )

    assert len(rows) == 1

    assert (
        rows[0]["ticket"]
        == "A"
    )


def test_admin_trade_ledger_sees_all_accounts(
    db
):
    _,account1=seed_user_account(
        db,
        "admin1@example.com",
        "601",
    )

    _,account2=seed_user_account(
        db,
        "admin2@example.com",
        "602",
    )

    with db() as s:
        s.add(
            TradeRecord(
                account_id=account1,
                symbol="BTCUSD",
                side="BUY",
                tier="FLIPPER",
                state="CLOSED",
                ticket="AA",
            )
        )

        s.add(
            TradeRecord(
                account_id=account2,
                symbol="BTCUSD",
                side="SELL",
                tier="MASTER",
                state="OPENED",
                ticket="BB",
            )
        )

    rows=api.admin_trades(
        limit=100,
        state=None,
        account_id=None,
        admin=SimpleNamespace(
            role="superadmin"
        ),
    )

    assert {
        x["ticket"]
        for x in rows
    } == {
        "AA",
        "BB",
    }