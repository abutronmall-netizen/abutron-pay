from __future__ import annotations

from prometheus_client import Gauge


COMPONENT_UP = Gauge(
    "abutron_jarvis_component_up",
    "Whether a monitored component is healthy (1) or not (0)",
    ["component"],
)

COMPONENT_LATENCY_MS = Gauge(
    "abutron_jarvis_component_latency_ms",
    "Latest deterministic health-check latency in milliseconds",
    ["component"],
)

SYSTEM_CPU_PERCENT = Gauge(
    "abutron_jarvis_system_cpu_percent",
    "Current Windows CPU utilization percent",
)

SYSTEM_MEMORY_PERCENT = Gauge(
    "abutron_jarvis_system_memory_percent",
    "Current Windows memory utilization percent",
)

SYSTEM_DISK_PERCENT = Gauge(
    "abutron_jarvis_system_disk_percent",
    "Current system-disk utilization percent",
)

COLLECTION_DURATION_MS = Gauge(
    "abutron_jarvis_health_collection_duration_ms",
    "Duration of the latest unified health collection",
)

OVERALL_READY = Gauge(
    "abutron_jarvis_overall_ready",
    "Whether all required production health checks are ready",
)


def record_snapshot(snapshot) -> None:
    for name, component in snapshot.components.items():
        COMPONENT_UP.labels(component=name).set(1 if component.status == "ok" else 0)
        if component.latency_ms is not None:
            COMPONENT_LATENCY_MS.labels(component=name).set(component.latency_ms)

    SYSTEM_CPU_PERCENT.set(snapshot.resources.cpu_percent)
    SYSTEM_MEMORY_PERCENT.set(snapshot.resources.memory_percent)
    SYSTEM_DISK_PERCENT.set(snapshot.resources.disk_percent)
    COLLECTION_DURATION_MS.set(snapshot.duration_ms)
    OVERALL_READY.set(1 if snapshot.ready else 0)
