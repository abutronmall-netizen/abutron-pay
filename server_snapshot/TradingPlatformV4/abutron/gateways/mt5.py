import httpx
from abutron.config import settings
from abutron.models import AccountState,BrokerContext,MarketSnapshot

class MT5Gateway:
    def _headers(self):
        return {"Authorization":f"Bearer {settings.mt5_token}"}
    async def health(self):
        async with httpx.AsyncClient(timeout=10) as c:
            r=await c.get(f"{settings.mt5_url}/health"); r.raise_for_status(); return r.json()
    async def account(self):
        async with httpx.AsyncClient(timeout=10) as c:
            r=await c.get(f"{settings.mt5_url}/v1/account",headers=self._headers()); r.raise_for_status()
            return AccountState(**r.json())
    async def positions(self):
        async with httpx.AsyncClient(timeout=10) as c:
            r=await c.get(f"{settings.mt5_url}/v1/positions",headers=self._headers()); r.raise_for_status(); return r.json()
    async def history(self,days=30):
        async with httpx.AsyncClient(timeout=20) as c:
            r=await c.get(f"{settings.mt5_url}/v1/history",params={"days":days},headers=self._headers()); r.raise_for_status(); return r.json()
    async def broker_context(self,symbol):
        async with httpx.AsyncClient(timeout=10) as c:
            r=await c.get(f"{settings.mt5_url}/v1/context/{symbol}",headers=self._headers()); r.raise_for_status()
            return BrokerContext(**r.json())
    async def bars(self,symbol,timeframe,count=512):
        async with httpx.AsyncClient(timeout=20) as c:
            r=await c.get(f"{settings.mt5_url}/v1/bars/{symbol}",
                params={"timeframe":timeframe,"count":count},headers=self._headers()); r.raise_for_status()
            return MarketSnapshot(**r.json())
    async def order(self,plan):
        async with httpx.AsyncClient(timeout=20) as c:
            r=await c.post(f"{settings.mt5_url}/v1/order",json=plan.model_dump(mode="json"),headers=self._headers())
            r.raise_for_status(); return r.json()
    async def manage(self):
        async with httpx.AsyncClient(timeout=20) as c:
            r=await c.post(f"{settings.mt5_url}/v1/manage",headers=self._headers()); r.raise_for_status(); return r.json()
    async def close(self,ticket:int):
        async with httpx.AsyncClient(timeout=20) as c:
            r=await c.post(f"{settings.mt5_url}/v1/close/{ticket}",headers=self._headers()); r.raise_for_status(); return r.json()
