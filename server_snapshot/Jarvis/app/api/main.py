import os
import time
import psutil
from fastapi import FastAPI,Header,HTTPException
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST,Gauge,generate_latest
from app.core.settings import settings
from app.core.state import init_db
from app.agents.guardian import observe
from app.integrations.hermes_intelligence import health as hermes_health
from app.integrations.whatsapp.webhook import router as whatsapp_router
from app.api.intelligence import router as intelligence_router
from app.api.system_health import router as system_health_router
app=FastAPI(title="Abutron Jarvis",version="1.1.0")

_JARVIS_PROCESS = psutil.Process(os.getpid())
_JARVIS_STARTED_AT = _JARVIS_PROCESS.create_time()

jarvis_process_cpu_percent = Gauge(
    "jarvis_process_cpu_percent",
    "Jarvis process CPU usage percentage"
)

jarvis_process_memory_bytes = Gauge(
    "jarvis_process_memory_bytes",
    "Jarvis resident memory usage in bytes"
)

jarvis_process_uptime_seconds = Gauge(
    "jarvis_process_uptime_seconds",
    "Jarvis process uptime in seconds"
)

app.include_router(whatsapp_router)
app.include_router(intelligence_router)
app.include_router(system_health_router)
@app.on_event("startup")
def start():init_db()
@app.get("/metrics",include_in_schema=False)
def metrics():
    jarvis_process_cpu_percent.set(
        _JARVIS_PROCESS.cpu_percent(interval=None)
    )
    jarvis_process_memory_bytes.set(
        _JARVIS_PROCESS.memory_info().rss
    )
    jarvis_process_uptime_seconds.set(
        max(0.0, time.time() - _JARVIS_STARTED_AT)
    )
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST
    )

@app.get("/health")
async def health():
    hermes = await hermes_health()
    return {
        "status": "ok" if hermes.get("status") == "ok" else "degraded",
        "mode": settings.jarvis_mode,
        "hermes": hermes,
    }
@app.get("/observe")
async def obs(x_jarvis_token:str|None=Header(None)):
 if x_jarvis_token!=settings.jarvis_api_token:raise HTTPException(401)
 return await observe()
