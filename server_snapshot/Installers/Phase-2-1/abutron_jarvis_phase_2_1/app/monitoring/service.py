from __future__ import annotations

import asyncio
import time
from datetime import datetime, timezone

from app.monitoring.collectors import (
    collect_database,
    collect_grafana,
    collect_kronos,
    collect_mt5_bridge,
    collect_mt5_process,
    collect_prometheus,
    collect_redis,
    collect_resources,
    collect_windows_exporter,
)
from app.monitoring.config import DEFAULT_CONFIG, HealthCollectorConfig
from app.monitoring.metrics import record_snapshot
from app.monitoring.models import ComponentHealth, UnifiedHealthSnapshot


async def _collect_hermes() -> ComponentHealth:
    """Use Jarvis' already-hardened Hermes client instead of a raw unauthenticated probe."""
    started = time.perf_counter()
    try:
        from app.integrations.hermes_intelligence import health as hermes_health

        result = await hermes_health()
        status = "ok" if result.get("status") == "ok" else "degraded"
        details = {
            "models": list(result.get("models", []))[:8],
        }
        if result.get("latency_ms") is not None:
            details["client_latency_ms"] = result.get("latency_ms")

        return ComponentHealth(
            name="hermes",
            status=status,
            required=True,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details=details,
        )
    except Exception as exc:
        return ComponentHealth(
            name="hermes",
            status="down",
            required=True,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            error=f"{exc.__class__.__name__}: {exc}"[:300],
        )


async def collect_unified_health(
    *,
    mode: str,
    cfg: HealthCollectorConfig = DEFAULT_CONFIG,
) -> UnifiedHealthSnapshot:
    """Collect all production telemetry concurrently without mutating the host."""
    started = time.perf_counter()

    component_coroutines = [
        collect_kronos(cfg),
        collect_mt5_bridge(cfg),
        collect_mt5_process(cfg),
        _collect_hermes(),
        collect_database(cfg),
        collect_redis(cfg),
        collect_prometheus(cfg),
        collect_grafana(cfg),
        collect_windows_exporter(cfg),
    ]

    try:
        results = await asyncio.wait_for(
            asyncio.gather(*component_coroutines),
            timeout=cfg.total_timeout_seconds,
        )
    except TimeoutError:
        results = [
            ComponentHealth(
                name="collector",
                status="down",
                required=True,
                error="UNIFIED_COLLECTION_TIMEOUT",
            )
        ]

    resources = await collect_resources(cfg)

    components = {item.name: item for item in results}

    required_unhealthy = [
        item
        for item in components.values()
        if item.required and item.status != "ok"
    ]

    ready = not required_unhealthy and resources.status == "ok"
    overall_status = "ok" if ready else "degraded"

    counts = {
        status: sum(1 for item in components.values() if item.status == status)
        for status in ("ok", "degraded", "down", "disabled", "unknown")
    }

    bridge = components.get("mt5_bridge")
    bridge_details = bridge.details if bridge else {}

    safety = {
        "observe_only": mode == "OBSERVE_ONLY",
        "mt5_live_trading": bridge_details.get("live_trading"),
        "mt5_management_enabled": bridge_details.get("management_enabled"),
        "collector_mutates_host": False,
    }

    snapshot = UnifiedHealthSnapshot(
        status=overall_status,
        ready=ready,
        mode=mode,
        collected_at=datetime.now(timezone.utc).isoformat(),
        duration_ms=round((time.perf_counter() - started) * 1000, 2),
        components=components,
        resources=resources,
        safety=safety,
        summary=counts,
    )

    record_snapshot(snapshot)
    return snapshot
