from __future__ import annotations
import json,secrets,time
from contextlib import asynccontextmanager
from fastapi import Cookie,FastAPI,Header,HTTPException,Query
from fastapi.responses import HTMLResponse,RedirectResponse
from . import __version__,store
from .config import settings
from .oauth import build_authorization_url,create_link_ticket,exchange_code,get_access_token
from .models import MarketOrderRequest,ClosePositionRequest,AmendPositionRequest
from .service import worker_request,stable_hash
from .worker_manager import manager,WorkerError

@asynccontextmanager
async def lifespan(_app):
    store.init_db(); manager.start()
    yield
    manager.stop()

app=FastAPI(title='Abutron IC Markets cTrader Cloud Gateway',version=__version__,lifespan=lifespan)

def internal_auth(key):
    if not settings.secrets_configured: raise HTTPException(503,'CTRADER_GATEWAY_SECRETS_NOT_CONFIGURED')
    if not secrets.compare_digest(str(key or ''),settings.internal_api_key): raise HTTPException(401,'Unauthorized')

def fresh(ts):
    age=abs(int(time.time())-int(ts))
    if age>settings.max_command_age_seconds: raise HTTPException(409,f'STALE_COMMAND age={age}s')

def execution_guard(env):
    if settings.kill_switch: raise HTTPException(423,'CTRADER_KILL_SWITCH_ACTIVE')
    if env=='DEMO' and not settings.demo_execution_enabled: raise HTTPException(403,'CTRADER_DEMO_EXECUTION_DISABLED')
    if env=='LIVE':
        if not settings.enable_live_connection: raise HTTPException(403,'CTRADER_LIVE_CONNECTION_DISABLED')
        if not settings.live_money_authorized: raise HTTPException(403,'LIVE_MONEY_AUTHORIZED_FALSE')

def linked(user_id,account_id):
    row=store.get_account(user_id,account_id)
    if not row: raise HTTPException(404,'LINKED_CTRADER_ACCOUNT_NOT_FOUND')
    return row

def _norm_broker(value:str|None)->str:
    return ''.join(ch for ch in str(value or '').upper() if ch.isalnum())

def allowed_broker(value:str|None)->bool:
    n=_norm_broker(value)
    markers=[_norm_broker(x) for x in settings.allowed_broker_markers.split(',') if x.strip()]
    return bool(n) and any(m and m in n for m in markers)

def _first_symbol_detail(payload:dict)->dict:
    resp=payload.get('response',{})
    rows=resp.get('symbol') or []
    if not rows: raise HTTPException(502,'CTRADER_SYMBOL_DETAILS_EMPTY')
    return rows[0]

def validate_protocol_volume(payload:dict,volume:int):
    sym=_first_symbol_detail(payload)
    minv=int(sym.get('min_volume') or sym.get('minVolume') or 0)
    step=int(sym.get('step_volume') or sym.get('stepVolume') or 0)
    maxv=int(sym.get('max_volume') or sym.get('maxVolume') or 0)
    if minv and volume<minv: raise HTTPException(409,'CTRADER_VOLUME_BELOW_MINIMUM')
    if maxv and volume>maxv: raise HTTPException(409,'CTRADER_VOLUME_ABOVE_MAXIMUM')
    if step and minv and (volume-minv)%step!=0: raise HTTPException(409,'CTRADER_VOLUME_STEP_INVALID')
    if step and not minv and volume%step!=0: raise HTTPException(409,'CTRADER_VOLUME_STEP_INVALID')


def _resp(payload:dict)->dict:
    return payload.get('response',{}) if isinstance(payload,dict) else {}

def _money(value, digits)->float:
    return float(int(value or 0))/(10**int(digits or 0))

def _norm_symbol(value)->str:
    return ''.join(ch for ch in str(value or '').upper() if ch.isalnum())

def _find_symbol(symbol_payload:dict, canonical='XAUUSD')->dict:
    rows=_resp(symbol_payload).get('symbol') or []
    wanted=_norm_symbol(canonical)
    for row in rows:
        name=row.get('symbol_name',row.get('symbolName',''))
        if _norm_symbol(name)==wanted and bool(row.get('enabled',True)):
            return row
    raise HTTPException(409,f'CTRADER_SYMBOL_NOT_FOUND:{canonical}')

def _deposit_asset(trader_payload:dict, assets_payload:dict)->dict:
    tr=_resp(trader_payload).get('trader') or _resp(trader_payload)
    asset_id=int(tr.get('deposit_asset_id') or tr.get('depositAssetId') or 0)
    for asset in (_resp(assets_payload).get('asset') or []):
        aid=int(asset.get('asset_id') or asset.get('assetId') or 0)
        if aid==asset_id:
            return {'asset_id':aid,'name':str(asset.get('name') or ''),'display_name':str(asset.get('display_name',asset.get('displayName','')) or '')}
    raise HTTPException(502,'CTRADER_DEPOSIT_ASSET_NOT_FOUND')

def _equity_snapshot(trader_payload:dict,pnl_payload:dict)->dict:
    tr=_resp(trader_payload).get('trader') or _resp(trader_payload)
    digits=int(tr.get('money_digits') or tr.get('moneyDigits') or 0)
    balance=_money(tr.get('balance'),digits)
    pnlr=_resp(pnl_payload)
    pnl_digits=int(pnlr.get('money_digits') or pnlr.get('moneyDigits') or digits)
    rows=pnlr.get('position_unrealized_pnl') or pnlr.get('positionUnrealizedPnL') or []
    net=sum(_money(x.get('net_unrealized_pnl',x.get('netUnrealizedPnL',0)),pnl_digits) for x in rows)
    return {'balance':balance,'net_unrealized_pnl':net,'equity':balance+net,'money_digits':digits,'open_position_pnl_count':len(rows)}

def _usd_equity_route(equity:float)->str:
    if 20 <= equity <= 3000: return 'FLIPPER'
    if 3000 < equity <= 5000: return 'SCALPER'
    if 5000 < equity <= 10000: return 'MASTER'
    return 'INELIGIBLE'

def _positions(payload:dict)->list[dict]:
    resp=payload.get('response',{})
    return resp.get('position') or []

def assert_abutron_position(payload:dict,position_id:int,requested_volume:int|None=None):
    for pos in _positions(payload):
        pid=int(pos.get('position_id') or pos.get('positionId') or 0)
        if pid!=int(position_id): continue
        td=pos.get('trade_data') or pos.get('tradeData') or {}
        label=str(td.get('label') or '').upper()
        if not label.startswith('ABUTRON'): raise HTTPException(403,'POSITION_NOT_ABUTRON_MANAGED')
        current=int(td.get('volume') or 0)
        if requested_volume is not None and (requested_volume<=0 or requested_volume>current): raise HTTPException(409,'CLOSE_VOLUME_EXCEEDS_POSITION')
        return pos
    raise HTTPException(404,'POSITION_NOT_FOUND_IN_RECONCILIATION')

async def idem_execute(body,operation):
    d=body.model_dump(); h=stable_hash(d)
    state=store.reserve_idempotency(body.idempotency_key,body.user_id,body.ctid_account_id,h)
    if state['state']=='CONFLICT': raise HTTPException(409,'IDEMPOTENCY_KEY_CONFLICT')
    if state['state']=='REPLAY': return {'idempotent_replay':True,'result':json.loads(state['response_json'])}
    if state['state'] in {'PENDING','UNCERTAIN'}: raise HTTPException(409,f"IDEMPOTENCY_{state['state']}_REQUIRES_RECONCILIATION")
    try:
        result=await operation(); store.complete_idempotency(body.idempotency_key,result)
        return {'idempotent_replay':False,'result':result}
    except Exception as exc:
        store.mark_uncertain(body.idempotency_key,str(exc)); raise

@app.get('/health')
def health():
    return {'status':'ok','version':__version__,'credentials_configured':settings.credentials_configured,'secrets_configured':settings.secrets_configured,
      'demo_connection_enabled':settings.enable_demo_connection,'live_connection_enabled':settings.enable_live_connection,
      'demo_execution_enabled':settings.demo_execution_enabled,'live_money_authorized':settings.live_money_authorized,'kill_switch':settings.kill_switch,
      'workers':manager.statuses() if settings.credentials_configured else {}}

@app.post('/v1/ctrader/oauth/ticket')
def oauth_ticket(user_id:str=Query(...,min_length=1),x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key)
    t=create_link_ticket(user_id)
    return {'start_url':f"{settings.public_base_url.rstrip('/')}/v1/ctrader/oauth/start?ticket={t}",'scope':settings.oauth_scope,'expires_in':settings.link_ticket_ttl_seconds}

@app.get('/v1/ctrader/oauth/start')
def oauth_start(ticket:str):
    store.get_state(ticket,settings.link_ticket_ttl_seconds)
    r=RedirectResponse(build_authorization_url(),302)
    r.set_cookie('abutron_ctrader_link',ticket,max_age=settings.link_ticket_ttl_seconds,httponly=True,secure=True,samesite='lax',path='/v1/ctrader/oauth')
    return r

@app.get('/v1/ctrader/oauth/callback',response_class=HTMLResponse)
async def oauth_callback(code:str,abutron_ctrader_link:str|None=Cookie(default=None)):
    if not abutron_ctrader_link: raise HTTPException(400,'OAUTH_LINK_COOKIE_MISSING')
    try:
        uid=store.consume_state(abutron_ctrader_link,settings.link_ticket_ttl_seconds)
        await exchange_code(uid,code); store.audit('CTRADER_OAUTH_CALLBACK_PASS',user_id=uid)
    except Exception:
        raise HTTPException(400,'CTRADER_OAUTH_CALLBACK_FAILED')
    r=HTMLResponse('<html><body><h2>IC Markets cTrader connected to Abutron.</h2><p>Return to the Abutron app.</p></body></html>')
    r.delete_cookie('abutron_ctrader_link',path='/v1/ctrader/oauth'); return r

@app.post('/v1/ctrader/users/{user_id}/unlink')
def unlink(user_id:str,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); store.delete_link(user_id); store.audit('CTRADER_UNLINK',user_id=user_id); return {'unlinked':True}

@app.post('/v1/ctrader/users/{user_id}/accounts/refresh')
async def refresh_accounts(user_id:str,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); token=await get_access_token(user_id); found={}
    successful_envs=0
    envs=[]
    if settings.enable_demo_connection: envs.append('DEMO')
    if settings.enable_live_connection: envs.append('LIVE')
    for env in envs:
        try: payload=await worker_request(env,'accounts',access_token=token)
        except WorkerError: continue
        successful_envs += 1
        resp=payload.get('response',{}); rows=resp.get('ctid_trader_account') or resp.get('ctidTraderAccount') or []
        for a in rows:
            aid=int(a.get('ctid_trader_account_id') or a.get('ctidTraderAccountId'))
            is_live=bool(a.get('is_live',a.get('isLive',False))); actual='LIVE' if is_live else 'DEMO'
            if actual!=env: continue
            broker=a.get('broker_title_short',a.get('brokerTitleShort'))
            if not allowed_broker(broker):
                store.audit('CTRADER_ACCOUNT_REJECTED_NON_IC',user_id=user_id,account_id=aid,broker_title=broker,environment=actual)
                continue
            found[aid]={'ctid_account_id':aid,'trader_login':a.get('trader_login',a.get('traderLogin')),'broker_title':broker,'environment':actual}
    if successful_envs == 0:
        raise HTTPException(503,'CTRADER_ACCOUNT_DISCOVERY_UNAVAILABLE')
    store.replace_accounts(user_id,list(found.values())); store.audit('CTRADER_ACCOUNT_REFRESH_PASS',user_id=user_id,count=len(found))
    return {'accounts':store.list_accounts(user_id)}

@app.get('/v1/ctrader/users/{user_id}/accounts')
def accounts(user_id:str,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); return {'accounts':store.list_accounts(user_id)}

async def read_action(user_id,account_id,action,**kwargs):
    a=linked(user_id,account_id); token=await get_access_token(user_id)
    return await worker_request(str(a['environment']).upper(),action,access_token=token,account_id=account_id,**kwargs)

@app.get('/v1/ctrader/users/{user_id}/accounts/{account_id}/trader')
async def trader(user_id:str,account_id:int,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); return await read_action(user_id,account_id,'trader')

@app.get('/v1/ctrader/users/{user_id}/accounts/{account_id}/reconcile')
async def reconcile(user_id:str,account_id:int,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); return await read_action(user_id,account_id,'reconcile')

@app.get('/v1/ctrader/users/{user_id}/accounts/{account_id}/symbols')
async def symbols(user_id:str,account_id:int,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); return await read_action(user_id,account_id,'symbols')

@app.get('/v1/ctrader/users/{user_id}/accounts/{account_id}/symbols/{symbol_id}')
async def symbol_details(user_id:str,account_id:int,symbol_id:int,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); return await read_action(user_id,account_id,'symbol-details',symbol_id=symbol_id)


@app.get('/v1/ctrader/users/{user_id}/accounts/{account_id}/discovery')
async def discovery(user_id:str,account_id:int,x_abutron_internal_key:str|None=Header(default=None)):
    """Step 21B read-only discovery. Never sends an order."""
    internal_auth(x_abutron_internal_key)
    account=linked(user_id,account_id)
    env=str(account['environment']).upper()
    if env!='DEMO': raise HTTPException(409,'STEP21B_REQUIRES_DEMO_ACCOUNT')
    token=await get_access_token(user_id)
    trader_payload=await worker_request(env,'trader',access_token=token,account_id=account_id)
    assets_payload=await worker_request(env,'assets',access_token=token,account_id=account_id)
    symbols_payload=await worker_request(env,'symbols',access_token=token,account_id=account_id)
    reconcile_payload=await worker_request(env,'reconcile',access_token=token,account_id=account_id)
    pnl_payload=await worker_request(env,'pnl',access_token=token,account_id=account_id)
    xau=_find_symbol(symbols_payload,'XAUUSD')
    symbol_id=int(xau.get('symbol_id') or xau.get('symbolId') or 0)
    details_payload=await worker_request(env,'symbol-details',access_token=token,account_id=account_id,symbol_id=symbol_id)
    detail=_first_symbol_detail(details_payload)
    asset=_deposit_asset(trader_payload,assets_payload)
    eq=_equity_snapshot(trader_payload,pnl_payload)
    currency=str(asset.get('name') or '').upper()
    route=_usd_equity_route(eq['equity']) if currency=='USD' else 'CURRENCY_CONVERSION_REQUIRED'
    result={
      'step':'21B','zero_order':True,'environment':env,'ctid_account_id':int(account_id),
      'trader_login':account['trader_login'],'broker_title':account['broker_title'],
      'deposit_currency':currency,'account':eq,'equity_route':route,
      'router_currency_ready':currency=='USD','positions_total':len(_positions(reconcile_payload)),
      'symbol':{
        'canonical':'XAUUSD','symbol_id':symbol_id,'broker_name':xau.get('symbol_name',xau.get('symbolName')),
        'min_volume':int(detail.get('min_volume') or detail.get('minVolume') or 0),
        'step_volume':int(detail.get('step_volume') or detail.get('stepVolume') or 0),
        'max_volume':int(detail.get('max_volume') or detail.get('maxVolume') or 0),
        'lot_size':int(detail.get('lot_size') or detail.get('lotSize') or 0),
        'digits':int(detail.get('digits') or 0),'pip_position':int(detail.get('pip_position') or detail.get('pipPosition') or 0),
      },
      'execution':{'demo_execution_enabled':settings.demo_execution_enabled,'live_money_authorized':settings.live_money_authorized,'kill_switch':settings.kill_switch},
    }
    store.audit('STEP21B_DISCOVERY_PASS',user_id=user_id,account_id=account_id,environment=env,deposit_currency=currency,equity_route=route,symbol_id=symbol_id)
    return result

@app.post('/v1/ctrader/orders/market')
async def market_order(body:MarketOrderRequest,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); fresh(body.command_timestamp)
    a=linked(body.user_id,body.ctid_account_id); env=str(a['environment']).upper(); execution_guard(env)
    token=await get_access_token(body.user_id)
    details=await worker_request(env,'symbol-details',access_token=token,account_id=body.ctid_account_id,symbol_id=body.symbol_id)
    validate_protocol_volume(details,body.protocol_volume)
    # Defence-in-depth: do not net/merge an Abutron order into a manual position on the same symbol.
    rec=await worker_request(env,'reconcile',access_token=token,account_id=body.ctid_account_id)
    for pos in _positions(rec):
        td=pos.get('trade_data') or pos.get('tradeData') or {}
        if int(td.get('symbol_id') or td.get('symbolId') or 0)==body.symbol_id and not str(td.get('label') or '').upper().startswith('ABUTRON'):
            raise HTTPException(409,'MANUAL_POSITION_CONFLICT')
    async def op():
        return await worker_request(env,'market-order',access_token=token,account_id=body.ctid_account_id,symbol_id=body.symbol_id,side=body.side,
            protocol_volume=body.protocol_volume,stop_loss=body.stop_loss,take_profit=body.take_profit,client_order_id=body.idempotency_key)
    out=await idem_execute(body,op)
    store.audit('CTRADER_MARKET_ORDER',body.user_id,body.ctid_account_id,environment=env,symbol_id=body.symbol_id,side=body.side,protocol_volume=body.protocol_volume)
    return out

@app.post('/v1/ctrader/positions/close')
async def close(body:ClosePositionRequest,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); fresh(body.command_timestamp)
    a=linked(body.user_id,body.ctid_account_id); env=str(a['environment']).upper(); execution_guard(env)
    token=await get_access_token(body.user_id)
    rec=await worker_request(env,'reconcile',access_token=token,account_id=body.ctid_account_id)
    assert_abutron_position(rec,body.position_id,body.protocol_volume)
    async def op():
        return await worker_request(env,'close-position',access_token=token,account_id=body.ctid_account_id,position_id=body.position_id,protocol_volume=body.protocol_volume)
    out=await idem_execute(body,op)
    store.audit('CTRADER_CLOSE_POSITION',body.user_id,body.ctid_account_id,environment=env,position_id=body.position_id)
    return out

@app.post('/v1/ctrader/positions/amend')
async def amend(body:AmendPositionRequest,x_abutron_internal_key:str|None=Header(default=None)):
    internal_auth(x_abutron_internal_key); fresh(body.command_timestamp)
    a=linked(body.user_id,body.ctid_account_id); env=str(a['environment']).upper(); execution_guard(env)
    if body.stop_loss is None and body.take_profit is None: raise HTTPException(400,'STOP_LOSS_OR_TAKE_PROFIT_REQUIRED')
    token=await get_access_token(body.user_id)
    rec=await worker_request(env,'reconcile',access_token=token,account_id=body.ctid_account_id)
    assert_abutron_position(rec,body.position_id)
    async def op():
        return await worker_request(env,'amend-position',access_token=token,account_id=body.ctid_account_id,position_id=body.position_id,stop_loss=body.stop_loss,take_profit=body.take_profit)
    out=await idem_execute(body,op)
    store.audit('CTRADER_AMEND_POSITION',body.user_id,body.ctid_account_id,environment=env,position_id=body.position_id)
    return out
