import httpx
from app.core.settings import settings
async def _get(path):
 async with httpx.AsyncClient(timeout=10) as c:
  r=await c.get(settings.kronos_base_url+path);r.raise_for_status();return r.json()
async def health():return await _get(settings.kronos_health_path)
async def readiness():return await _get(settings.kronos_ready_path)
