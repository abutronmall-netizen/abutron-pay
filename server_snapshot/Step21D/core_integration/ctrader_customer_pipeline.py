"""Step 21C adapter: existing Kronos intelligence + customer cTrader account/broker state.

No execution selector is changed globally. This adapter is invoked only by Step 21C certification
or the future customer worker after certification.
"""
from __future__ import annotations
from sqlalchemy import select
from abutron.models import AccountState,BrokerContext,MarketBundle,BotTier
from abutron.profiles import profile_for
from abutron.platform_db import session_scope,License,TradingAccount,TradeRecord
from abutron.gateways.ctrader_cloud import CTraderCloudGateway
from abutron.service import TradingService
from abutron.gateways.ctrader_volume import lots_to_protocol_volume
import json,time

def _license_active(user_id:int)->bool:
    now=int(time.time())
    with session_scope() as s:
        rows=list(s.scalars(select(License).where(License.user_id==int(user_id))).all())
    return any(str(x.status).lower()=='active' and (x.expires_ts is None or int(x.expires_ts)>now) for x in rows)

def _broker_from(preflight:dict):
    s=preflight['symbol']; q=preflight['spot']
    digits=int(s['digits']); point=10.0**(-digits); lot_units=float(s['lot_size'])/100.0
    if point<=0 or lot_units<=0: raise RuntimeError('CTRADER_SYMBOL_ECONOMICS_INVALID')
    # Step 21C is deliberately USD + XAUUSD only, so one price unit per base unit is USD P/L.
    tick_value=lot_units*point
    lot_size=float(s['lot_size'])
    return BrokerContext(symbol='XAUUSD',bid=float(q['bid']),ask=float(q['ask']),point=point,tick_size=point,tick_value=tick_value,
        volume_min=float(s['min_volume'])/lot_size,volume_max=float(s['max_volume'])/lot_size,volume_step=float(s['step_volume'])/lot_size,
        spread_points=(float(q['ask'])-float(q['bid']))/point,positions_on_symbol=int(preflight['target_positions']))

def _account_from(discovery:dict,user_id:int):
    a=discovery['account']
    if discovery.get('deposit_currency')!='USD': raise RuntimeError('STEP21C_USD_ACCOUNT_REQUIRED')
    daily=float(discovery.get('_step21c_daily_realized_pnl',0.0))
    return AccountState(equity=float(a['equity']),balance=float(a['balance']),daily_pnl=daily,open_risk=0.0,
        license_active=_license_active(user_id),positions_total=int(discovery.get('positions_total',0)),login=str(discovery.get('trader_login') or ''),
        server='IC Markets cTrader DEMO',currency='USD')

async def build_customer_pipeline(user_id:int,ctid_account_id:int,symbol='XAUUSD'):
    gw=CTraderCloudGateway(); svc=TradingService()
    discovery=await gw.discovery(user_id,ctid_account_id)
    preflight=await gw.step21c_preflight(user_id,ctid_account_id)
    if discovery.get('equity_route') not in {'FLIPPER','SCALPER','MASTER'}: raise RuntimeError('STEP21C_EQUITY_ROUTE_INELIGIBLE')
    if preflight.get('target_positions')!=0 or preflight.get('target_orders')!=0: raise RuntimeError('STEP21C_ZERO_TARGET_BASELINE_REQUIRED')
    if int(preflight.get('positions_total',0))!=0: raise RuntimeError('STEP21C_REQUIRES_CLEAN_ACCOUNT_POSITION_BASELINE')
    discovery['_step21c_daily_realized_pnl']=float(preflight.get('daily_realized_pnl',0.0))
    account=_account_from(discovery,user_id); broker=_broker_from(preflight)
    tier=BotTier(discovery['equity_route']); profile=profile_for(tier)
    # Centralized market intelligence remains on the already-certified market-data bridge.
    # Only account/broker execution state is replaced by cTrader customer state.
    primary=await svc.gateway.bars(symbol,profile.primary_tf)
    contexts={tf:await svc.gateway.bars(symbol,tf) for tf in profile.context_tfs}
    result=svc.evaluate(MarketBundle(primary=primary,contexts=contexts),account,broker,current_tier=None)
    if result.route.selected.value!=discovery['equity_route']: raise RuntimeError('STEP21C_ROUTE_MISMATCH')
    return result,discovery,preflight

def build_lifecycle_request(result,discovery,preflight,user_id:int,ctid_account_id:int):
    if not result.risk.approved or result.risk.reason!='APPROVED': raise RuntimeError('KRONOS_RISK_NOT_APPROVED')
    if result.plan is None: raise RuntimeError('KRONOS_NO_ORDER_PLAN')
    if result.decision.value not in {'BUY','SELL'}: raise RuntimeError('KRONOS_DECISION_NOT_EXECUTABLE')
    s=preflight['symbol']
    protocol_volume=lots_to_protocol_volume(result.plan.volume,lot_size_cents=int(s['lot_size']),min_volume=int(s['min_volume']),step_volume=int(s['step_volume']),max_volume=int(s['max_volume']))
    return {'user_id':str(user_id),'ctid_account_id':int(ctid_account_id),'symbol_id':int(preflight['symbol_id']),'side':result.plan.direction.value,
      'protocol_volume':protocol_volume,'planned_entry':float(result.plan.entry),'stop_loss':float(result.plan.sl),'take_profit':float(result.plan.tp),
      'tier':result.route.selected.value,'strategy_profile':result.plan.strategy_profile,'risk_approved':True,'risk_reason':result.risk.reason,
      'risk_amount':float(result.plan.risk_amount),'idempotency_key':result.plan.idempotency_key}

def _close_profit(lifecycle:dict)->float:
    broker=(lifecycle.get('result') or lifecycle)
    close=(broker.get('close') or {}).get('response') or {}
    deal=close.get('deal') or {}
    d=deal.get('close_position_detail') or deal.get('closePositionDetail') or {}
    if not d: return 0.0
    digits=int(d.get('money_digits') or d.get('moneyDigits') or deal.get('money_digits') or deal.get('moneyDigits') or 0)
    scale=10**digits
    gross=float(int(d.get('gross_profit',d.get('grossProfit',0)) or 0))/scale
    swap=float(int(d.get('swap',0) or 0))/scale
    commission=float(int(d.get('commission',0) or 0))/scale
    fee=float(int(d.get('pnl_conversion_fee',d.get('pnlConversionFee',0)) or 0))/scale
    return gross+swap+commission-fee

def persist_closed_lifecycle(result,lifecycle,discovery,user_id:int,ctid_account_id:int):
    broker_result=(lifecycle.get('result') or lifecycle); position_id=str(broker_result.get('position_id') or '')
    trader_login=str(discovery.get('trader_login') or ctid_account_id); server=f"cTrader DEMO:{int(ctid_account_id)}"; realized=_close_profit(lifecycle)
    with session_scope() as s:
        acct=s.scalar(select(TradingAccount).where(TradingAccount.user_id==int(user_id),TradingAccount.broker=='IC Markets cTrader',TradingAccount.login==trader_login))
        if acct is None:
            acct=TradingAccount(user_id=int(user_id),broker='IC Markets cTrader',login=trader_login,server=server,symbol='XAUUSD',current_tier=result.route.selected.value,active=True); s.add(acct); s.flush()
        existing=s.scalar(select(TradeRecord).where(TradeRecord.signal_id==result.plan.idempotency_key))
        if existing is None:
            s.add(TradeRecord(account_id=acct.id,symbol='XAUUSD',side=result.plan.direction.value,tier=result.route.selected.value,state='CLOSED',ticket=position_id,
                volume=float(result.plan.volume),entry=float(result.plan.entry),sl=float(result.plan.sl),tp=float(result.plan.tp),profit=realized,signal_id=result.plan.idempotency_key,
                opened_ts=int(time.time()),closed_ts=int(time.time()),payload=json.dumps({'pipeline':result.model_dump(mode='json'),'ctrader':lifecycle,'ctid_account_id':int(ctid_account_id)},default=str)))
        acct.current_tier=result.route.selected.value; acct.server=server
    return {'db_reconciled':True,'signal_id':result.plan.idempotency_key,'position_id':position_id,'realized_profit':realized}
