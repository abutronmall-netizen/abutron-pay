from __future__ import annotations
import argparse,asyncio,json,os,sys,time,uuid
from pathlib import Path
import httpx
ROOT=Path(r'C:\Abutron\TradingPlatformV4')
GATEWAY=ROOT/'ctrader_cloud_gateway'
sys.path.insert(0,str(GATEWAY))
from ctrader_gateway import store
from ctrader_gateway.config import settings

async def call(client,method,path,**kwargs):
    h={'X-Abutron-Internal-Key':settings.internal_api_key}
    r=await client.request(method,path,headers=h,**kwargs)
    if r.status_code>=400: raise RuntimeError(f'{path}:{r.status_code}:{r.text[:500]}')
    return r.json()

async def main(a):
    if settings.live_money_authorized or settings.enable_live_connection: raise RuntimeError('LIVE_MONEY_OR_CONNECTION_MUST_REMAIN_FALSE')
    # Create a durable synthetic UNCERTAIN key without sending anything to the broker.
    key='step21d-'+uuid.uuid4().hex[:24]; h='synthetic-'+uuid.uuid4().hex
    rs=store.reserve_idempotency(key,str(a.user_id),int(a.account_id),h)
    if rs.get('state')!='RESERVED': raise RuntimeError('SYNTHETIC_IDEMPOTENCY_RESERVE_FAIL')
    store.mark_uncertain(key,'STEP21D_SYNTHETIC_TRANSPORT_AMBIGUITY_NO_BROKER_MUTATION')
    base=f'http://127.0.0.1:{settings.port}'
    async with httpx.AsyncClient(timeout=30) as c:
        restart=await call(c,'POST',f'/v1/ctrader/step21d/users/{a.user_id}/accounts/{a.account_id}/restart-worker')
        refresh=await call(c,'POST',f'/v1/ctrader/step21d/users/{a.user_id}/token-refresh')
        inspect=await call(c,'GET',f'/v1/ctrader/step21d/users/{a.user_id}/accounts/{a.account_id}/recovery-status',params={'idempotency_key':key})
    if inspect.get('automatic_retry_allowed') is not False: raise RuntimeError('UNCERTAIN_AUTO_RETRY_MUST_BE_FALSE')
    if inspect.get('broker_order_sent_by_recovery') is not False: raise RuntimeError('RECOVERY_MUST_NOT_SEND_ORDER')
    print('STEP21D_REAL_RECOVERY_CERT=PASS')
    print('WORKER_RESTART=PASS')
    print('TOKEN_REFRESH=PASS')
    print('UNCERTAIN_AUTO_RETRY=False')
    print('LIVE_MONEY_AUTHORIZED=False')
    print('BROKER_ORDER_SENT=False')
    print(json.dumps({'restart':restart,'refresh':refresh,'recovery':inspect},default=str))

if __name__=='__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--user-id',type=int,required=True); ap.add_argument('--account-id',type=int,required=True)
    raise SystemExit(asyncio.run(main(ap.parse_args())))
