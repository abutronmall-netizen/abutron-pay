from __future__ import annotations

import asyncio

import httpx
import pytest

from app.monitoring.collectors import http_health, collect_mt5_bridge
from app.monitoring.config import HealthCollectorConfig
from app.monitoring.models import ComponentHealth, SystemResources
from app.monitoring import service


@pytest.mark.asyncio
async def test_http_health_rejects_non_loopback():
    result = await http_health(
        name="bad",
        url="http://example.com/health",
        required=True,
        timeout_seconds=0.1,
    )
    assert result.status == "down"
    assert result.error == "NON_LOOPBACK_TARGET_REJECTED"


@pytest.mark.asyncio
async def test_http_health_parses_mt5_safety_fields(monkeypatch):
    async def handler(request):
        return httpx.Response(
            200,
            headers={"content-type": "application/json"},
            json={
                "status": "ok",
                "mt5_connected": True,
                "live_trading": False,
                "management_enabled": False,
            },
        )

    transport = httpx.MockTransport(handler)
    real_async_client = httpx.AsyncClient

    class FakeClient:
        async def __aenter__(self):
            self.client = real_async_client(transport=transport)
            return self.client

        async def __aexit__(self, *args):
            await self.client.aclose()

    monkeypatch.setattr(httpx, "AsyncClient", lambda *a, **k: FakeClient())

    result = await http_health(
        name="bridge",
        url="http://127.0.0.1:8090/health",
        required=True,
        timeout_seconds=1.0,
    )
    assert result.status == "ok"
    assert result.details["mt5_connected"] is True
    assert result.details["live_trading"] is False


@pytest.mark.asyncio
async def test_unified_health_degrades_when_required_component_down(monkeypatch):
    ok = lambda name: ComponentHealth(name=name, status="ok", required=True)

    async def fake_kronos(cfg): return ok("kronos")
    async def fake_bridge(cfg): return ComponentHealth(name="mt5_bridge", status="down", required=True)
    async def fake_mt5(cfg): return ok("mt5_terminal")
    async def fake_db(cfg): return ok("database")
    async def fake_redis(cfg): return ComponentHealth(name="redis", status="disabled", required=False)
    async def fake_prom(cfg): return ok("prometheus")
    async def fake_graf(cfg): return ComponentHealth(name="grafana", status="ok", required=False)
    async def fake_win(cfg): return ok("windows_exporter")
    async def fake_hermes(): return ok("hermes")
    async def fake_resources(cfg):
        return SystemResources(status="ok", cpu_percent=10, memory_percent=20, disk_percent=30)

    monkeypatch.setattr(service, "collect_kronos", fake_kronos)
    monkeypatch.setattr(service, "collect_mt5_bridge", fake_bridge)
    monkeypatch.setattr(service, "collect_mt5_process", fake_mt5)
    monkeypatch.setattr(service, "collect_database", fake_db)
    monkeypatch.setattr(service, "collect_redis", fake_redis)
    monkeypatch.setattr(service, "collect_prometheus", fake_prom)
    monkeypatch.setattr(service, "collect_grafana", fake_graf)
    monkeypatch.setattr(service, "collect_windows_exporter", fake_win)
    monkeypatch.setattr(service, "_collect_hermes", fake_hermes)
    monkeypatch.setattr(service, "collect_resources", fake_resources)
    monkeypatch.setattr(service, "record_snapshot", lambda snapshot: None)

    snap = await service.collect_unified_health(
        mode="OBSERVE_ONLY",
        cfg=HealthCollectorConfig(total_timeout_seconds=1),
    )
    assert snap.status == "degraded"
    assert snap.ready is False
    assert snap.safety["collector_mutates_host"] is False


@pytest.mark.asyncio
async def test_unified_health_ok_when_required_components_ok(monkeypatch):
    def comp(name, required=True):
        return ComponentHealth(name=name, status="ok", required=required)

    async def fake(name, required=True): return comp(name, required)

    monkeypatch.setattr(service, "collect_kronos", lambda cfg: fake("kronos"))
    monkeypatch.setattr(service, "collect_mt5_bridge", lambda cfg: fake("mt5_bridge"))
    monkeypatch.setattr(service, "collect_mt5_process", lambda cfg: fake("mt5_terminal"))
    monkeypatch.setattr(service, "collect_database", lambda cfg: fake("database"))
    monkeypatch.setattr(service, "collect_redis", lambda cfg: asyncio.sleep(0, result=ComponentHealth(name="redis", status="disabled", required=False)))
    monkeypatch.setattr(service, "collect_prometheus", lambda cfg: fake("prometheus"))
    monkeypatch.setattr(service, "collect_grafana", lambda cfg: fake("grafana", False))
    monkeypatch.setattr(service, "collect_windows_exporter", lambda cfg: fake("windows_exporter"))
    monkeypatch.setattr(service, "_collect_hermes", lambda: fake("hermes"))
    monkeypatch.setattr(service, "collect_resources", lambda cfg: asyncio.sleep(0, result=SystemResources(status="ok", cpu_percent=10, memory_percent=20, disk_percent=30)))
    monkeypatch.setattr(service, "record_snapshot", lambda snapshot: None)

    snap = await service.collect_unified_health(mode="OBSERVE_ONLY")
    assert snap.status == "ok"
    assert snap.ready is True
    assert snap.mode == "OBSERVE_ONLY"


@pytest.mark.asyncio
async def test_mt5_bridge_probe_is_tcp_only_and_reads_safety(monkeypatch, tmp_path):
    env = tmp_path / ".env"
    env.write_text(
        "ABUTRON_EXECUTION_ENABLED=false\n"
        "MT5_LIVE_TRADING=false\n"
        "MT5_MANAGEMENT_ENABLED=false\n"
        "MT5_DEMO_ONLY=true\n",
        encoding="utf-8",
    )

    class FakeSocket:
        def __enter__(self): return self
        def __exit__(self, *args): return False

    import app.monitoring.collectors as collectors
    monkeypatch.setattr(collectors.socket, "create_connection", lambda *a, **k: FakeSocket())

    cfg = HealthCollectorConfig(
        mt5_bridge_base_url="http://127.0.0.1:8090",
        trading_env_path=str(env),
        request_timeout_seconds=0.1,
    )
    result = await collect_mt5_bridge(cfg)

    assert result.status == "ok"
    assert result.details["probe"] == "tcp_only"
    assert result.details["live_trading"] is False
    assert result.details["management_enabled"] is False
    assert result.details["execution_enabled"] is False
    assert result.details["demo_only"] is True
