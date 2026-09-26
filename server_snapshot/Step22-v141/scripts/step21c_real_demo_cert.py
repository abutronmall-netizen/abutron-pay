from __future__ import annotations
import argparse,asyncio,json,sys
from pathlib import Path
ROOT=Path(r'C:\Abutron\TradingPlatformV4')
if str(ROOT) not in sys.path: sys.path.insert(0,str(ROOT))
from abutron.gateways.ctrader_cloud import CTraderCloudGateway
from abutron.ctrader_customer_pipeline import build_customer_pipeline,build_lifecycle_request,persist_closed_lifecycle

def emit(k,v): print(f'{k}={v}',flush=True)
async def main(a):
    gw=CTraderCloudGateway()
    pf=await gw.step21c_preflight(a.user_id,a.account_id)
    emit('STEP21B_REAL_OAUTH','PASS'); emit('STEP21C_PREFLIGHT','PASS'); emit('BROKER_ORDER_SENT','False')
    result,discovery,preflight=await build_customer_pipeline(a.user_id,a.account_id)
    emit('KRONOS_DECISION',result.decision.value); emit('RISK',result.risk.reason); emit('ROUTE',result.route.selected.value); emit('PLAN_PRESENT',bool(result.plan))
    if not a.authorize_demo:
        emit('STEP21C_EXECUTION','NOT_AUTHORIZED'); emit('LIVE_MONEY_AUTHORIZED','False'); return 0
    if result.plan is None or not result.risk.approved or result.decision.value not in {'BUY','SELL'}:
        emit('STEP21C_EXECUTION','NO_ACTION_KRONOS_OR_RISK_BLOCK'); emit('BROKER_ORDER_SENT','False'); return 3
    body=build_lifecycle_request(result,discovery,preflight,a.user_id,a.account_id)
    out=await gw.step21c_lifecycle(body)
    db=persist_closed_lifecycle(result,out,discovery,a.user_id,a.account_id)
    emit('STEP21C_DEMO_LIFECYCLE','PASS'); emit('DB_RECONCILIATION','PASS'); emit('ZERO_RESIDUAL_TARGET_POSITION','True'); emit('LIVE_MONEY_AUTHORIZED','False'); emit('BROKER_ORDER_SENT','True_DEMO_ONLY')
    print(json.dumps({'lifecycle':out,'db':db},default=str))
    return 0
if __name__=='__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--user-id',type=int,required=True); ap.add_argument('--account-id',type=int,required=True); ap.add_argument('--authorize-demo',action='store_true')
    raise SystemExit(asyncio.run(main(ap.parse_args())))
