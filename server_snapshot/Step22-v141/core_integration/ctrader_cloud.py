"""HTTP client for the Abutron core. This module has no Spotware SDK dependency."""
from __future__ import annotations
import os,time,httpx

class CTraderCloudGateway:
    def __init__(self,url=None,internal_key=None):
        self.url=(url or os.getenv('ABUTRON_CTRADER_GATEWAY_URL','http://127.0.0.1:8091')).rstrip('/')
        self.key=internal_key or os.getenv('ABUTRON_CTRADER_GATEWAY_INTERNAL_KEY','')
    def _h(self): return {'X-Abutron-Internal-Key':self.key}
    async def health(self):
        async with httpx.AsyncClient(timeout=10) as c: r=await c.get(f'{self.url}/health'); r.raise_for_status(); return r.json()
    async def oauth_ticket(self,user_id):
        async with httpx.AsyncClient(timeout=10) as c: r=await c.post(f'{self.url}/v1/ctrader/oauth/ticket',params={'user_id':str(user_id)},headers=self._h()); r.raise_for_status(); return r.json()
    async def refresh_accounts(self,user_id):
        async with httpx.AsyncClient(timeout=20) as c: r=await c.post(f'{self.url}/v1/ctrader/users/{user_id}/accounts/refresh',headers=self._h()); r.raise_for_status(); return r.json()
    async def accounts(self,user_id):
        async with httpx.AsyncClient(timeout=10) as c: r=await c.get(f'{self.url}/v1/ctrader/users/{user_id}/accounts',headers=self._h()); r.raise_for_status(); return r.json()
    async def trader(self,user_id,account_id):
        async with httpx.AsyncClient(timeout=10) as c: r=await c.get(f'{self.url}/v1/ctrader/users/{user_id}/accounts/{account_id}/trader',headers=self._h()); r.raise_for_status(); return r.json()
    async def reconcile(self,user_id,account_id):
        async with httpx.AsyncClient(timeout=15) as c: r=await c.get(f'{self.url}/v1/ctrader/users/{user_id}/accounts/{account_id}/reconcile',headers=self._h()); r.raise_for_status(); return r.json()
    async def symbols(self,user_id,account_id):
        async with httpx.AsyncClient(timeout=15) as c: r=await c.get(f'{self.url}/v1/ctrader/users/{user_id}/accounts/{account_id}/symbols',headers=self._h()); r.raise_for_status(); return r.json()
    async def symbol_details(self,user_id,account_id,symbol_id):
        async with httpx.AsyncClient(timeout=15) as c: r=await c.get(f'{self.url}/v1/ctrader/users/{user_id}/accounts/{account_id}/symbols/{symbol_id}',headers=self._h()); r.raise_for_status(); return r.json()
    async def discovery(self,user_id,account_id):
        async with httpx.AsyncClient(timeout=25) as c: r=await c.get(f'{self.url}/v1/ctrader/users/{user_id}/accounts/{account_id}/discovery',headers=self._h()); r.raise_for_status(); return r.json()
    async def unlink(self,user_id):
        async with httpx.AsyncClient(timeout=10) as c: r=await c.post(f'{self.url}/v1/ctrader/users/{user_id}/unlink',headers=self._h()); r.raise_for_status(); return r.json()
    async def market_order(self,*,user_id,account_id,symbol_id,side,protocol_volume,idempotency_key,relative_stop_loss=None,relative_take_profit=None):
        body={'user_id':str(user_id),'ctid_account_id':int(account_id),'symbol_id':int(symbol_id),'side':side,'protocol_volume':int(protocol_volume),
              'relative_stop_loss':relative_stop_loss,'relative_take_profit':relative_take_profit,'idempotency_key':idempotency_key,'command_timestamp':int(time.time())}
        async with httpx.AsyncClient(timeout=20) as c: r=await c.post(f'{self.url}/v1/ctrader/orders/market',json=body,headers=self._h()); r.raise_for_status(); return r.json()
    async def close_position(self,*,user_id,account_id,position_id,protocol_volume,idempotency_key):
        body={'user_id':str(user_id),'ctid_account_id':int(account_id),'position_id':int(position_id),'protocol_volume':int(protocol_volume),'idempotency_key':idempotency_key,'command_timestamp':int(time.time())}
        async with httpx.AsyncClient(timeout=20) as c: r=await c.post(f'{self.url}/v1/ctrader/positions/close',json=body,headers=self._h()); r.raise_for_status(); return r.json()

    async def step21c_preflight(self,user_id,account_id):
        async with httpx.AsyncClient(timeout=25) as c: r=await c.get(f'{self.url}/v1/ctrader/step21c/users/{user_id}/accounts/{account_id}/preflight',headers=self._h()); r.raise_for_status(); return r.json()
    async def step21c_lifecycle(self,body):
        payload=dict(body); payload['command_timestamp']=int(time.time())
        async with httpx.AsyncClient(timeout=60) as c: r=await c.post(f'{self.url}/v1/ctrader/step21c/lifecycle',json=payload,headers=self._h()); r.raise_for_status(); return r.json()
