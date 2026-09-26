from __future__ import annotations

import os
from dataclasses import dataclass


def _bool_env(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _float_env(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


@dataclass(frozen=True, slots=True)
class HealthCollectorConfig:
    """Configuration for deterministic, read-only health collection.

    All network targets default to localhost. The collector never accepts a URL
    from request input, which prevents it from becoming an SSRF proxy.
    """

    kronos_base_url: str = os.getenv(
        "JARVIS_HEALTH_KRONOS_BASE_URL", "http://127.0.0.1:8088"
    ).rstrip("/")
    kronos_health_path: str = os.getenv(
        "JARVIS_HEALTH_KRONOS_PATH", "/health"
    )

    mt5_bridge_base_url: str = os.getenv(
        "JARVIS_HEALTH_MT5_BRIDGE_BASE_URL", "http://127.0.0.1:8090"
    ).rstrip("/")
    mt5_bridge_health_path: str = os.getenv(
        "JARVIS_HEALTH_MT5_BRIDGE_PATH", "/health"
    )

    prometheus_url: str = os.getenv(
        "JARVIS_HEALTH_PROMETHEUS_URL", "http://127.0.0.1:9090/-/ready"
    )
    grafana_url: str = os.getenv(
        "JARVIS_HEALTH_GRAFANA_URL", "http://127.0.0.1:3000/api/health"
    )
    windows_exporter_url: str = os.getenv(
        "JARVIS_HEALTH_WINDOWS_EXPORTER_URL", "http://127.0.0.1:9182/metrics"
    )

    mt5_process_name: str = os.getenv(
        "JARVIS_HEALTH_MT5_PROCESS", "terminal64.exe"
    )
    state_db_path: str = os.getenv(
        "JARVIS_HEALTH_DB_PATH", r"C:\Abutron\Jarvis\data\jarvis.db"
    )

    request_timeout_seconds: float = _float_env(
        "JARVIS_HEALTH_HTTP_TIMEOUT", 3.0
    )
    total_timeout_seconds: float = _float_env(
        "JARVIS_HEALTH_TOTAL_TIMEOUT", 8.0
    )

    redis_enabled: bool = _bool_env("JARVIS_HEALTH_REDIS_ENABLED", False)
    redis_host: str = os.getenv("JARVIS_HEALTH_REDIS_HOST", "127.0.0.1")
    redis_port: int = int(os.getenv("JARVIS_HEALTH_REDIS_PORT", "6379"))

    prometheus_required: bool = _bool_env(
        "JARVIS_HEALTH_PROMETHEUS_REQUIRED", True
    )
    grafana_required: bool = _bool_env("JARVIS_HEALTH_GRAFANA_REQUIRED", False)
    windows_exporter_required: bool = _bool_env(
        "JARVIS_HEALTH_WINDOWS_EXPORTER_REQUIRED", True
    )
    database_required: bool = _bool_env("JARVIS_HEALTH_DATABASE_REQUIRED", True)

    cpu_warn_percent: float = _float_env("JARVIS_HEALTH_CPU_WARN", 90.0)
    memory_warn_percent: float = _float_env("JARVIS_HEALTH_MEMORY_WARN", 90.0)
    disk_warn_percent: float = _float_env("JARVIS_HEALTH_DISK_WARN", 90.0)


DEFAULT_CONFIG = HealthCollectorConfig()
