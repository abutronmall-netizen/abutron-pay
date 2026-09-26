from __future__ import annotations
import time
import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Header, HTTPException
from sqlalchemy import select
from abutron.config import settings
from abutron.platform_db import User, session_scope

_ph=PasswordHasher(time_cost=3,memory_cost=65536,parallelism=4)

def hash_password(password:str)->str:
    if len(password)<10:
        raise ValueError("Password must contain at least 10 characters")
    return _ph.hash(password)

def verify_password(password:str,password_hash:str)->bool:
    try:
        return _ph.verify(password_hash,password)
    except VerifyMismatchError:
        return False

def issue_token(user:User, ttl_seconds:int=3600)->str:
    now=int(time.time())
    payload={"sub":str(user.id),"email":user.email,"role":user.role,"iat":now,"exp":now+ttl_seconds,"iss":"abutron-v4"}
    return jwt.encode(payload,settings.jwt_secret,algorithm="HS256")

def decode_token(token:str)->dict:
    try:
        return jwt.decode(token,settings.jwt_secret,algorithms=["HS256"],issuer="abutron-v4")
    except Exception as e:
        raise HTTPException(401,"Invalid or expired token") from e

def current_user(authorization:str|None=Header(default=None))->User:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401,"Bearer token required")
    payload=decode_token(authorization.split(" ",1)[1])
    with session_scope() as s:
        u=s.get(User,int(payload["sub"]))
        if not u or not u.active:
            raise HTTPException(401,"User inactive or not found")
        s.expunge(u)
        return u

def require_admin(authorization:str|None=Header(default=None))->User:
    u=current_user(authorization)
    if u.role not in {"admin","superadmin"}:
        raise HTTPException(403,"Admin role required")
    return u
