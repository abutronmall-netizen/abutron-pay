"""Customer-facing IC Markets cTrader linking routes for Abutron v4.
No execution endpoints are exposed here. Step 21B is read-only/zero-order.
"""
from __future__ import annotations
from fastapi import APIRouter,Depends,HTTPException
from abutron.security import current_user
from abutron.gateways.ctrader_cloud import CTraderCloudGateway

router=APIRouter(prefix='/v1/broker/ic-markets',tags=['IC Markets cTrader'])
gw=CTraderCloudGateway()

@router.post('/connect')
async def connect_ic_markets(user=Depends(current_user)):
    try: return await gw.oauth_ticket(user.id)
    except Exception as exc: raise HTTPException(502,'CTRADER_LINK_START_FAILED') from exc

@router.get('/accounts')
async def ic_accounts(user=Depends(current_user)):
    try: return await gw.accounts(user.id)
    except Exception as exc: raise HTTPException(502,'CTRADER_ACCOUNTS_READ_FAILED') from exc

@router.post('/accounts/refresh')
async def refresh_ic_accounts(user=Depends(current_user)):
    try: return await gw.refresh_accounts(user.id)
    except Exception as exc: raise HTTPException(502,'CTRADER_ACCOUNT_REFRESH_FAILED') from exc

@router.get('/accounts/{account_id}/discovery')
async def ic_account_discovery(account_id:int,user=Depends(current_user)):
    try: return await gw.discovery(user.id,account_id)
    except Exception as exc: raise HTTPException(502,'CTRADER_DISCOVERY_FAILED') from exc

@router.delete('/connect')
async def disconnect_ic_markets(user=Depends(current_user)):
    try: return await gw.unlink(user.id)
    except Exception as exc: raise HTTPException(502,'CTRADER_UNLINK_FAILED') from exc
