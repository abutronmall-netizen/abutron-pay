from __future__ import annotations
import secrets,time
from urllib.parse import urlencode
import httpx
from .config import settings
from .crypto import encrypt_secret,decrypt_secret
from . import store

def create_link_ticket(user_id:str)->str:
    ticket=secrets.token_urlsafe(32); store.create_state(ticket,str(user_id)); return ticket

def build_authorization_url()->str:
    if not settings.client_id: raise RuntimeError('CTRADER_CLIENT_ID_NOT_CONFIGURED')
    params={'client_id':settings.client_id,'redirect_uri':settings.redirect_uri,'scope':settings.oauth_scope,'product':'web'}
    return settings.oauth_authorize_url+'?'+urlencode(params)

async def _token_request(params:dict)->dict:
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r=await client.get(settings.oauth_token_url,params=params,headers={'Accept':'application/json'})
            r.raise_for_status(); data=r.json()
    except httpx.HTTPError as exc:
        # Never propagate an exception string containing the token endpoint query/client secret.
        raise RuntimeError('CTRADER_TOKEN_HTTP_FAILED') from exc
    if not data.get('accessToken') or not data.get('refreshToken'):
        raise RuntimeError('CTRADER_TOKEN_RESPONSE_INVALID')
    return data

async def exchange_code(user_id:str,code:str):
    if not settings.credentials_configured: raise RuntimeError('CTRADER_APP_CREDENTIALS_NOT_CONFIGURED')
    data=await _token_request({'grant_type':'authorization_code','code':code,'redirect_uri':settings.redirect_uri,'client_id':settings.client_id,'client_secret':settings.client_secret})
    expires=int(data.get('expiresIn') or 0)
    store.upsert_token(str(user_id),encrypt_secret(data['accessToken']),encrypt_secret(data['refreshToken']),int(time.time())+expires,settings.oauth_scope)
    store.audit('CTRADER_OAUTH_TOKEN_STORED',user_id=user_id,expires_in=expires)
    return {'expires_in':expires}

async def refresh_access_token(user_id:str):
    row=store.get_token(str(user_id))
    if not row: raise RuntimeError('CTRADER_TOKEN_NOT_LINKED')
    data=await _token_request({'grant_type':'refresh_token','refresh_token':decrypt_secret(row['refresh_token_enc']),'client_id':settings.client_id,'client_secret':settings.client_secret})
    expires=int(data.get('expiresIn') or 0)
    store.upsert_token(str(user_id),encrypt_secret(data['accessToken']),encrypt_secret(data['refreshToken']),int(time.time())+expires,str(row['scope']))
    store.audit('CTRADER_TOKEN_REFRESHED',user_id=user_id,expires_in=expires)

async def get_access_token(user_id:str)->str:
    row=store.get_token(str(user_id))
    if not row: raise RuntimeError('CTRADER_TOKEN_NOT_LINKED')
    if int(row['expires_at'])<=int(time.time())+300:
        await refresh_access_token(str(user_id)); row=store.get_token(str(user_id))
    return decrypt_secret(row['access_token_enc'])

async def force_refresh_access_token(user_id:str)->dict:
    """Rotate access+refresh tokens without returning either secret to the caller."""
    await refresh_access_token(str(user_id))
    row=store.get_token(str(user_id))
    if not row: raise RuntimeError('CTRADER_TOKEN_REFRESH_PERSISTENCE_FAIL')
    return {'refreshed':True,'expires_at':int(row['expires_at']),'scope':str(row['scope'])}
