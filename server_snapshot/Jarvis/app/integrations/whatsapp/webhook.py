import hashlib, hmac
from fastapi import APIRouter, Request, HTTPException, Query
from fastapi.responses import PlainTextResponse
import os

router=APIRouter(prefix="/webhooks/whatsapp", tags=["whatsapp"])

@router.get("")
async def verify(
    hub_mode: str = Query(alias="hub.mode"),
    hub_verify_token: str = Query(alias="hub.verify_token"),
    hub_challenge: str = Query(alias="hub.challenge"),
):
    expected=os.getenv("META_WEBHOOK_VERIFY_TOKEN","")
    if hub_mode=="subscribe" and expected and hmac.compare_digest(hub_verify_token,expected):
        return PlainTextResponse(hub_challenge)
    raise HTTPException(403)

@router.post("")
async def receive(request: Request):
    body=await request.body()
    secret=os.getenv("META_APP_SECRET","")
    signature=request.headers.get("x-hub-signature-256","")
    if secret:
        expected="sha256="+hmac.new(secret.encode(),body,hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature,expected):
            raise HTTPException(401,"Invalid Meta webhook signature")
    payload=await request.json()
    # Production dispatcher will route messages/calls to typed handlers.
    return {"received": True, "object": payload.get("object")}
