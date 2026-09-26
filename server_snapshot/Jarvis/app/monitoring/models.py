from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Literal

from pydantic import BaseModel, Field


ComponentStatus = Literal["ok", "degraded", "down", "disabled", "unknown"]


class ComponentHealth(BaseModel):
    name: str
    status: ComponentStatus
    required: bool = True
    latency_ms: float | None = None
    checked_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    details: dict[str, Any] = Field(default_factory=dict)
    error: str | None = None


class SystemResources(BaseModel):
    status: ComponentStatus
    cpu_percent: float
    memory_percent: float
    disk_percent: float
    boot_time_utc: str | None = None


class UnifiedHealthSnapshot(BaseModel):
    status: Literal["ok", "degraded"]
    ready: bool
    mode: str
    collected_at: str
    duration_ms: float
    components: dict[str, ComponentHealth]
    resources: SystemResources
    safety: dict[str, Any]
    summary: dict[str, int]
