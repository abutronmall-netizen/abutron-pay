from __future__ import annotations

import hmac

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from app.core.audit import audit
from app.core.policy import Decision, PolicyEngine
from app.core.settings import settings
from app.integrations.hermes_intelligence import (
    HermesIntelligenceError,
    HermesIntelligenceTimeout,
    query as hermes_query,
)


router = APIRouter()
policy = PolicyEngine()


class IntelligenceRequest(BaseModel):
    prompt: str = Field(
        min_length=1,
        max_length=8000,
    )


def _authorize(token: str | None) -> None:
    expected = str(settings.jarvis_api_token)

    if (
        not token
        or not expected
        or expected == "CHANGE_ME"
        or not hmac.compare_digest(token, expected)
    ):
        raise HTTPException(
            status_code=401,
            detail="Unauthorized",
        )


@router.post("/v1/intelligence/query")
async def intelligence_query(
    request: IntelligenceRequest,
    x_jarvis_token: str | None = Header(None),
):
    _authorize(x_jarvis_token)

    if settings.jarvis_mode != "OBSERVE_ONLY":
        audit(
            "hermes_intelligence_blocked",
            {
                "reason": "mode_not_observe_only",
                "mode": settings.jarvis_mode,
            },
        )

        raise HTTPException(
            status_code=409,
            detail="Jarvis intelligence endpoint requires OBSERVE_ONLY mode",
        )

    decision = policy.decide(
        "query_hermes_intelligence"
    )

    if decision != Decision.ALLOW:
        audit(
            "hermes_intelligence_blocked",
            {
                "reason": "policy",
                "decision": decision.value,
            },
        )

        raise HTTPException(
            status_code=403,
            detail="Denied by Jarvis policy",
        )

    try:
        result = await hermes_query(
            request.prompt
        )

    except HermesIntelligenceTimeout:
        audit(
            "hermes_intelligence_failure",
            {
                "error": "timeout",
                "prompt_chars": len(request.prompt),
            },
        )

        raise HTTPException(
            status_code=504,
            detail="Hermes intelligence timeout",
        )

    except HermesIntelligenceError as exc:
        audit(
            "hermes_intelligence_failure",
            {
                "error": str(exc),
                "prompt_chars": len(request.prompt),
            },
        )

        raise HTTPException(
            status_code=502,
            detail="Hermes intelligence unavailable",
        )

    audit(
        "hermes_intelligence_query",
        {
            "provider": result["provider"],
            "model": result["model"],
            "prompt_chars": len(request.prompt),
            "response_chars": len(result["answer"]),
            "latency_ms": result["latency_ms"],
            "mode": settings.jarvis_mode,
        },
    )

    return {
        "status": "ok",
        **result,
    }