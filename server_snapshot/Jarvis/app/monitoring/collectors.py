from __future__ import annotations

import asyncio
import socket
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import httpx
import psutil

from app.monitoring.config import HealthCollectorConfig
from app.monitoring.models import ComponentHealth, SystemResources


def _safe_error(exc: Exception) -> str:
    """Return a bounded, credential-free error string."""
    text = f"{exc.__class__.__name__}: {exc}"
    return text[:300]


def _localhost_url(url: str) -> bool:
    parsed = urlparse(url)
    return (
        parsed.scheme in {"http", "https"}
        and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
    )


def _join(base: str, path: str) -> str:
    if not path.startswith("/"):
        path = "/" + path
    return base.rstrip("/") + path


def _parse_bool(value: str | None) -> bool | None:
    if value is None:
        return None
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    return None


def _read_trading_safety_flags(cfg: HealthCollectorConfig) -> dict[str, Any]:
    """Read only non-secret execution safety flags from TradingPlatformV4 .env."""
    path = Path(cfg.trading_env_path)
    wanted = {
        "ABUTRON_EXECUTION_ENABLED": "execution_enabled",
        "MT5_LIVE_TRADING": "live_trading",
        "MT5_MANAGEMENT_ENABLED": "management_enabled",
        "MT5_DEMO_ONLY": "demo_only",
    }
    result: dict[str, Any] = {key: None for key in wanted.values()}
    result["safety_source"] = "trading_env"

    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except Exception as exc:
        result["safety_read_error"] = _safe_error(exc)
        return result

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        if name in wanted:
            result[wanted[name]] = _parse_bool(value)

    return result


def _tcp_probe_sync(
    *,
    name: str,
    base_url: str,
    required: bool,
    timeout_seconds: float,
    details: dict[str, Any] | None = None,
) -> ComponentHealth:
    """Passive TCP-only availability probe for local production services."""
    started = time.perf_counter()
    parsed = urlparse(base_url)
    host = parsed.hostname
    port = parsed.port

    if host not in {"127.0.0.1", "localhost", "::1"} or port is None:
        return ComponentHealth(
            name=name,
            status="down",
            required=required,
            error="INVALID_LOOPBACK_TCP_TARGET",
        )

    try:
        with socket.create_connection((host, port), timeout=timeout_seconds):
            pass
        merged = {"probe": "tcp_only", "port": port}
        if details:
            merged.update(details)
        return ComponentHealth(
            name=name,
            status="ok",
            required=required,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details=merged,
        )
    except Exception as exc:
        merged = {"probe": "tcp_only", "port": port}
        if details:
            merged.update(details)
        return ComponentHealth(
            name=name,
            status="down",
            required=required,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details=merged,
            error=_safe_error(exc),
        )


async def tcp_probe(
    *,
    name: str,
    base_url: str,
    required: bool,
    timeout_seconds: float,
    details: dict[str, Any] | None = None,
) -> ComponentHealth:
    return await asyncio.to_thread(
        _tcp_probe_sync,
        name=name,
        base_url=base_url,
        required=required,
        timeout_seconds=timeout_seconds,
        details=details,
    )


async def http_health(
    *,
    name: str,
    url: str,
    required: bool,
    timeout_seconds: float,
) -> ComponentHealth:
    started = time.perf_counter()

    if not _localhost_url(url):
        return ComponentHealth(
            name=name,
            status="down",
            required=required,
            error="NON_LOOPBACK_TARGET_REJECTED",
        )

    try:
        timeout = httpx.Timeout(timeout_seconds)
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
            response = await client.get(url)

        latency = round((time.perf_counter() - started) * 1000, 2)
        status = "ok" if 200 <= response.status_code < 300 else "down"
        details: dict[str, Any] = {"http_status": response.status_code}

        content_type = response.headers.get("content-type", "")
        if "application/json" in content_type:
            try:
                payload = response.json()
            except ValueError:
                payload = None
            if isinstance(payload, dict):
                service_status = payload.get("status")
                if service_status is not None:
                    details["service_status"] = str(service_status)[:80]
                    if str(service_status).lower() not in {
                        "ok",
                        "healthy",
                        "up",
                        "ready",
                    }:
                        status = "degraded"

                # Keep only known, non-secret operational fields.
                for key in (
                    "version",
                    "mt5_connected",
                    "terminal",
                    "live_trading",
                    "management_enabled",
                    "mode",
                ):
                    if key in payload:
                        details[key] = payload[key]

                if payload.get("mt5_connected") is False:
                    status = "degraded"

        return ComponentHealth(
            name=name,
            status=status,
            required=required,
            latency_ms=latency,
            details=details,
        )
    except Exception as exc:
        return ComponentHealth(
            name=name,
            status="down",
            required=required,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            error=_safe_error(exc),
        )


async def collect_kronos(cfg: HealthCollectorConfig) -> ComponentHealth:
    # Deliberately do not call TradingPlatformV4 /health here: that route cascades
    # to the MT5 gateway health endpoint, which calls mt5.initialize().
    return await tcp_probe(
        name="kronos",
        base_url=cfg.kronos_base_url,
        required=True,
        timeout_seconds=cfg.request_timeout_seconds,
        details={"http_probe_disabled": True},
    )


async def collect_mt5_bridge(cfg: HealthCollectorConfig) -> ComponentHealth:
    # Deliberately do not call /health. The bridge /health invokes
    # MetaTrader5.initialize(), which may attach to or launch a terminal.
    return await tcp_probe(
        name="mt5_bridge",
        base_url=cfg.mt5_bridge_base_url,
        required=True,
        timeout_seconds=cfg.request_timeout_seconds,
        details=_read_trading_safety_flags(cfg),
    )


async def collect_prometheus(cfg: HealthCollectorConfig) -> ComponentHealth:
    return await http_health(
        name="prometheus",
        url=cfg.prometheus_url,
        required=cfg.prometheus_required,
        timeout_seconds=cfg.request_timeout_seconds,
    )


async def collect_grafana(cfg: HealthCollectorConfig) -> ComponentHealth:
    return await http_health(
        name="grafana",
        url=cfg.grafana_url,
        required=cfg.grafana_required,
        timeout_seconds=cfg.request_timeout_seconds,
    )


async def collect_windows_exporter(cfg: HealthCollectorConfig) -> ComponentHealth:
    return await http_health(
        name="windows_exporter",
        url=cfg.windows_exporter_url,
        required=cfg.windows_exporter_required,
        timeout_seconds=cfg.request_timeout_seconds,
    )


def _collect_mt5_process_sync(cfg: HealthCollectorConfig) -> ComponentHealth:
    started = time.perf_counter()
    target = cfg.mt5_process_name.lower()
    matches: list[int] = []

    try:
        for proc in psutil.process_iter(["pid", "name"]):
            try:
                name = (proc.info.get("name") or "").lower()
                if name == target:
                    matches.append(int(proc.info["pid"]))
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        return ComponentHealth(
            name="mt5_terminal",
            status="ok" if matches else "down",
            required=True,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details={"process_count": len(matches)},
        )
    except Exception as exc:
        return ComponentHealth(
            name="mt5_terminal",
            status="unknown",
            required=True,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            error=_safe_error(exc),
        )


async def collect_mt5_process(cfg: HealthCollectorConfig) -> ComponentHealth:
    return await asyncio.to_thread(_collect_mt5_process_sync, cfg)


def _collect_database_sync(cfg: HealthCollectorConfig) -> ComponentHealth:
    started = time.perf_counter()
    path = Path(cfg.state_db_path)

    if not path.exists():
        return ComponentHealth(
            name="database",
            status="down",
            required=cfg.database_required,
            details={"type": "sqlite"},
            error="DATABASE_FILE_NOT_FOUND",
        )

    try:
        uri = path.resolve().as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=2.0) as conn:
            row = conn.execute("PRAGMA quick_check").fetchone()

        result = str(row[0]) if row else "unknown"
        return ComponentHealth(
            name="database",
            status="ok" if result.lower() == "ok" else "degraded",
            required=cfg.database_required,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details={"type": "sqlite", "quick_check": result[:80]},
        )
    except Exception as exc:
        return ComponentHealth(
            name="database",
            status="down",
            required=cfg.database_required,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details={"type": "sqlite"},
            error=_safe_error(exc),
        )


async def collect_database(cfg: HealthCollectorConfig) -> ComponentHealth:
    return await asyncio.to_thread(_collect_database_sync, cfg)


def _collect_redis_sync(cfg: HealthCollectorConfig) -> ComponentHealth:
    if not cfg.redis_enabled:
        return ComponentHealth(
            name="redis",
            status="disabled",
            required=False,
            details={"configured": False},
        )

    started = time.perf_counter()
    try:
        with socket.create_connection(
            (cfg.redis_host, cfg.redis_port),
            timeout=cfg.request_timeout_seconds,
        ) as sock:
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            reply = sock.recv(64)

        ok = reply.startswith(b"+PONG")
        return ComponentHealth(
            name="redis",
            status="ok" if ok else "degraded",
            required=True,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details={"configured": True},
        )
    except Exception as exc:
        return ComponentHealth(
            name="redis",
            status="down",
            required=True,
            latency_ms=round((time.perf_counter() - started) * 1000, 2),
            details={"configured": True},
            error=_safe_error(exc),
        )


async def collect_redis(cfg: HealthCollectorConfig) -> ComponentHealth:
    return await asyncio.to_thread(_collect_redis_sync, cfg)


def _system_disk_root() -> str:
    if psutil.WINDOWS:
        return "C:\\"
    return "/"


def _collect_resources_sync(cfg: HealthCollectorConfig) -> SystemResources:
    cpu = float(psutil.cpu_percent(interval=0.2))
    memory = float(psutil.virtual_memory().percent)
    disk = float(psutil.disk_usage(_system_disk_root()).percent)

    degraded = (
        cpu >= cfg.cpu_warn_percent
        or memory >= cfg.memory_warn_percent
        or disk >= cfg.disk_warn_percent
    )

    try:
        boot = datetime.fromtimestamp(
            psutil.boot_time(), tz=timezone.utc
        ).isoformat()
    except Exception:
        boot = None

    return SystemResources(
        status="degraded" if degraded else "ok",
        cpu_percent=round(cpu, 2),
        memory_percent=round(memory, 2),
        disk_percent=round(disk, 2),
        boot_time_utc=boot,
    )


async def collect_resources(cfg: HealthCollectorConfig) -> SystemResources:
    return await asyncio.to_thread(_collect_resources_sync, cfg)
