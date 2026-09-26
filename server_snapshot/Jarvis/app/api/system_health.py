from __future__ import annotations

import hmac

from fastapi import APIRouter, Header, HTTPException

from app.core.settings import settings
from app.monitoring.service import collect_unified_health


router = APIRouter(prefix="/v1/system", tags=["system-health"])


def _require_token(provided: str | None) -> None:
    expected = str(settings.jarvis_api_token or "").strip()
    supplied = str(provided or "").strip()

    if not expected or expected == "CHANGE_ME":
        raise HTTPException(status_code=503, detail="JARVIS_API_TOKEN_NOT_CONFIGURED")

    if not supplied or not hmac.compare_digest(supplied, expected):
        raise HTTPException(status_code=401, detail="UNAUTHORIZED")


@router.get("/health")
async def unified_system_health(
    x_jarvis_token: str | None = Header(default=None),
):
    _require_token(x_jarvis_token)
    snapshot = await collect_unified_health(mode=str(settings.jarvis_mode))
    return snapshot.model_dump(mode="json")
