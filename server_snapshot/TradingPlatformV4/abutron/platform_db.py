from __future__ import annotations
import time
from contextlib import contextmanager
from sqlalchemy import create_engine, String, Integer, Float, Boolean, Text, ForeignKey, select
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker, relationship
from abutron.config import settings

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__="users"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    email:Mapped[str]=mapped_column(String(255),unique=True,index=True)
    full_name:Mapped[str]=mapped_column(String(255),default="")
    phone:Mapped[str]=mapped_column(String(64),default="")
    password_hash:Mapped[str]=mapped_column(String(512))
    role:Mapped[str]=mapped_column(String(32),default="customer")
    active:Mapped[bool]=mapped_column(Boolean,default=True)
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

class TradingAccount(Base):
    __tablename__="trading_accounts"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    user_id:Mapped[int]=mapped_column(ForeignKey("users.id"),index=True)
    broker:Mapped[str]=mapped_column(String(128),default="IC Markets")
    login:Mapped[str]=mapped_column(String(128),default="")
    server:Mapped[str]=mapped_column(String(128),default="")
    symbol:Mapped[str]=mapped_column(String(32),default="XAUUSD")
    current_tier:Mapped[str]=mapped_column(String(32),default="")
    active:Mapped[bool]=mapped_column(Boolean,default=True)
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

class License(Base):
    __tablename__="licenses"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    user_id:Mapped[int]=mapped_column(ForeignKey("users.id"),index=True)
    product:Mapped[str]=mapped_column(String(64),default="ABUTRON_V4")
    status:Mapped[str]=mapped_column(String(32),default="active")
    expires_ts:Mapped[int|None]=mapped_column(Integer,nullable=True)
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

class Subscription(Base):
    __tablename__="subscriptions"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    user_id:Mapped[int]=mapped_column(ForeignKey("users.id"),index=True)
    plan:Mapped[str]=mapped_column(String(64),default="")
    status:Mapped[str]=mapped_column(String(32),default="pending")
    external_ref:Mapped[str]=mapped_column(String(255),default="")
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))
    updated_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

class TradeRecord(Base):
    __tablename__="trade_records"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    account_id:Mapped[int|None]=mapped_column(ForeignKey("trading_accounts.id"),nullable=True,index=True)
    symbol:Mapped[str]=mapped_column(String(32),index=True)
    side:Mapped[str]=mapped_column(String(8))
    tier:Mapped[str]=mapped_column(String(32),default="")
    state:Mapped[str]=mapped_column(String(32),default="PLANNED")
    ticket:Mapped[str]=mapped_column(String(64),default="")
    volume:Mapped[float]=mapped_column(Float,default=0.0)
    entry:Mapped[float]=mapped_column(Float,default=0.0)
    sl:Mapped[float]=mapped_column(Float,default=0.0)
    tp:Mapped[float]=mapped_column(Float,default=0.0)
    profit:Mapped[float]=mapped_column(Float,default=0.0)
    signal_id:Mapped[str]=mapped_column(String(128),default="",index=True)
    opened_ts:Mapped[int|None]=mapped_column(Integer,nullable=True)
    closed_ts:Mapped[int|None]=mapped_column(Integer,nullable=True)
    payload:Mapped[str]=mapped_column(Text,default="{}")
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

class Notification(Base):
    __tablename__="notifications"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    user_id:Mapped[int|None]=mapped_column(ForeignKey("users.id"),nullable=True,index=True)
    title:Mapped[str]=mapped_column(String(255))
    body:Mapped[str]=mapped_column(Text)
    channel:Mapped[str]=mapped_column(String(32),default="in_app")
    state:Mapped[str]=mapped_column(String(32),default="queued")
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

class AuditEvent(Base):
    __tablename__="audit_events"
    id:Mapped[int]=mapped_column(Integer,primary_key=True,autoincrement=True)
    actor:Mapped[str]=mapped_column(String(255),default="system")
    action:Mapped[str]=mapped_column(String(128),index=True)
    subject:Mapped[str]=mapped_column(String(255),default="")
    detail:Mapped[str]=mapped_column(Text,default="")
    created_ts:Mapped[int]=mapped_column(Integer,default=lambda:int(time.time()))

engine=create_engine(settings.platform_db_url, future=True, pool_pre_ping=True)
SessionLocal=sessionmaker(bind=engine,expire_on_commit=False,future=True)

def init_db():
    Base.metadata.create_all(engine)

@contextmanager
def session_scope():
    s=SessionLocal()
    try:
        yield s
        s.commit()
    except Exception:
        s.rollback()
        raise
    finally:
        s.close()

def audit(action:str,subject:str="",detail:str="",actor:str="system"):
    with session_scope() as s:
        s.add(AuditEvent(actor=actor,action=action,subject=subject,detail=detail))
