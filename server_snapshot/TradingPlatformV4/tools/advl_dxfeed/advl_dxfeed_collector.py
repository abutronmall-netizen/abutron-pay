from __future__ import annotations

import argparse
import base64
import json
import math
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

VERSION = "1.0.0"
DEFAULT_ROOT = Path(os.getenv("ABUTRON_ROOT", r"C:\Abutron\TradingPlatformV4"))
DEFAULT_DEMO_URL = "https://tools.dxfeed.com/webservice/rest/events.json"
DEFAULT_SYMBOLS = {
    "nyse_up": "$UVOLC",
    "nyse_down": "$DVOLC",
    "nasdaq_up": "$UVOLC/Q",
    "nasdaq_down": "$DVOLC/Q",
}


class CollectorError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    root: Path
    env_path: Path
    rest_url: str
    token: str
    username: str
    password: str
    mode: str
    poll_seconds: float
    window_seconds: int
    request_timeout: int
    max_event_age_seconds: int
    max_component_skew_seconds: int
    max_baseline_gap_seconds: int
    allow_demo_write: bool
    source: str
    universe: str
    symbols: dict[str, str]

    @property
    def feed_path(self) -> Path:
        return self.root / "runtime" / "advl_breadth.json"

    @property
    def status_path(self) -> Path:
        return self.root / "runtime" / "advl_dxfeed_status.json"

    @property
    def history_dir(self) -> Path:
        return self.root / "runtime" / "advl_history"

    @property
    def source_state_path(self) -> Path:
        return self.root / "runtime" / "advl_dxfeed_source_state.json"

    @property
    def log_dir(self) -> Path:
        return self.root / "runtime" / "logs"


def _bool_env(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _int_env(name: str, default: int, lo: int, hi: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        value = default
    return max(lo, min(hi, value))


def _float_env(name: str, default: float, lo: float, hi: float) -> float:
    try:
        value = float(os.getenv(name, str(default)))
    except ValueError:
        value = default
    if not math.isfinite(value):
        value = default
    return max(lo, min(hi, value))


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def build_settings(root: Path, env_path: Path | None = None) -> Settings:
    root = Path(root)
    env_path = env_path or root / "secrets" / "dxfeed_advl.env"
    load_env_file(env_path)

    mode = os.getenv("DXFEED_MODE", "demo").strip().lower()
    if mode not in {"demo", "production"}:
        raise CollectorError("DXFEED_MODE must be demo or production")

    rest_url = os.getenv("DXFEED_REST_URL", DEFAULT_DEMO_URL).strip()
    if not rest_url.startswith(("https://", "http://")):
        raise CollectorError("DXFEED_REST_URL must be an http(s) URL")

    token = os.getenv("DXFEED_TOKEN", "").strip()
    username = os.getenv("DXFEED_USERNAME", "").strip()
    password = os.getenv("DXFEED_PASSWORD", "").strip()
    if mode == "production" and not token and not (username and password):
        raise CollectorError(
            "Production mode requires DXFEED_TOKEN or DXFEED_USERNAME/DXFEED_PASSWORD"
        )

    symbols = {
        "nyse_up": os.getenv("DXFEED_NYSE_UP_SYMBOL", DEFAULT_SYMBOLS["nyse_up"]).strip(),
        "nyse_down": os.getenv("DXFEED_NYSE_DOWN_SYMBOL", DEFAULT_SYMBOLS["nyse_down"]).strip(),
        "nasdaq_up": os.getenv("DXFEED_NASDAQ_UP_SYMBOL", DEFAULT_SYMBOLS["nasdaq_up"]).strip(),
        "nasdaq_down": os.getenv("DXFEED_NASDAQ_DOWN_SYMBOL", DEFAULT_SYMBOLS["nasdaq_down"]).strip(),
    }
    if any(not x for x in symbols.values()):
        raise CollectorError("All four dxFeed market-indicator symbols must be configured")

    return Settings(
        root=root,
        env_path=env_path,
        rest_url=rest_url,
        token=token,
        username=username,
        password=password,
        mode=mode,
        poll_seconds=_float_env("DXFEED_POLL_SECONDS", 5.0, 2.0, 60.0),
        window_seconds=_int_env("DXFEED_WINDOW_SECONDS", 180, 30, 3600),
        request_timeout=_int_env("DXFEED_REQUEST_TIMEOUT_SECONDS", 10, 2, 60),
        max_event_age_seconds=_int_env("DXFEED_MAX_EVENT_AGE_SECONDS", 30, 5, 900),
        max_component_skew_seconds=_int_env("DXFEED_MAX_COMPONENT_SKEW_SECONDS", 20, 1, 300),
        max_baseline_gap_seconds=_int_env("DXFEED_MAX_BASELINE_GAP_SECONDS", 30, 5, 600),
        allow_demo_write=_bool_env("DXFEED_ALLOW_DELAYED_DEMO_WRITE", False),
        source=os.getenv("DXFEED_SOURCE_LABEL", "DXFEED_MARKET_INDICATORS").strip()
        or "DXFEED_MARKET_INDICATORS",
        universe=os.getenv("DXFEED_UNIVERSE_LABEL", "NYSE+NASDAQ_COMPOSITE").strip()
        or "NYSE+NASDAQ_COMPOSITE",
        symbols=symbols,
    )


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        except OSError:
            pass


def _safe_float(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(result):
        return None
    return result


def _normalize_epoch(value: Any) -> int:
    parsed = _safe_float(value)
    if parsed is None:
        return 0
    while abs(parsed) > 10_000_000_000:
        parsed /= 1000.0
    return int(parsed)


def event_timestamp(event: dict[str, Any]) -> int:
    for key in ("time", "eventTime", "timestamp", "asof_ts", "ts"):
        if key in event:
            result = _normalize_epoch(event.get(key))
            if result > 0:
                return result
    return 0


def event_price(event: dict[str, Any]) -> float | None:
    for key in ("price", "Price", "value", "Value"):
        if key in event:
            value = _safe_float(event.get(key))
            if value is not None:
                return value
    return None


def _walk_event_container(node: Any, fallback_symbol: str | None = None) -> Iterable[dict[str, Any]]:
    if isinstance(node, list):
        for item in node:
            yield from _walk_event_container(item, fallback_symbol)
        return
    if not isinstance(node, dict):
        return

    looks_like_event = any(key in node for key in ("price", "Price", "time", "eventTime"))
    if looks_like_event:
        event = dict(node)
        if fallback_symbol and not event.get("eventSymbol"):
            event["eventSymbol"] = fallback_symbol
        yield event
        return

    for key, value in node.items():
        symbol_hint = key if isinstance(key, str) and key.startswith("$") else fallback_symbol
        yield from _walk_event_container(value, symbol_hint)


def extract_time_and_sale_events(payload: dict[str, Any]) -> list[dict[str, Any]]:
    container = payload.get("TimeAndSale")
    if container is None:
        container = payload.get("timeAndSale")
    if container is None:
        raise CollectorError("dxFeed response contains no TimeAndSale data")
    return list(_walk_event_container(container))


def latest_event_by_symbol(payload: dict[str, Any], symbols: Iterable[str]) -> dict[str, dict[str, Any]]:
    wanted = set(symbols)
    latest: dict[str, dict[str, Any]] = {}
    for event in extract_time_and_sale_events(payload):
        symbol = str(event.get("eventSymbol", ""))
        if symbol not in wanted:
            continue
        ts = event_timestamp(event)
        current = latest.get(symbol)
        if current is None or ts >= event_timestamp(current):
            latest[symbol] = event
    return latest


def _format_dx_time(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def request_snapshot(settings: Settings, now_ts: int | None = None) -> dict[str, Any]:
    now_ts = int(time.time()) if now_ts is None else int(now_ts)
    symbols = list(dict.fromkeys(settings.symbols.values()))
    body = urllib.parse.urlencode(
        {
            "events": "TimeAndSale",
            "symbols": ",".join(symbols),
            "fromTime": _format_dx_time(now_ts - settings.window_seconds),
            "toTime": _format_dx_time(now_ts + 2),
            "timeout": str(min(settings.request_timeout, 15)),
        }
    ).encode("utf-8")
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": f"Abutron-ADVL-dxFeed/{VERSION}",
    }
    if settings.token:
        headers["Authorization"] = f"Bearer {settings.token}"
    elif settings.username and settings.password:
        basic = base64.b64encode(f"{settings.username}:{settings.password}".encode("utf-8")).decode("ascii")
        headers["Authorization"] = f"Basic {basic}"

    request = urllib.request.Request(settings.rest_url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=settings.request_timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise CollectorError(f"dxFeed HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise CollectorError(f"dxFeed network error: {exc.reason}") from exc

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CollectorError("dxFeed returned non-JSON data") from exc
    if not isinstance(payload, dict):
        raise CollectorError("dxFeed response is not a JSON object")
    status = str(payload.get("status", "OK")).upper()
    if status not in {"OK", "SUCCESS"}:
        raise CollectorError(f"dxFeed status={status}")
    return payload


def build_breadth_sample(payload: dict[str, Any], settings: Settings, now_ts: int | None = None) -> dict[str, Any]:
    now_ts = int(time.time()) if now_ts is None else int(now_ts)
    symbols = settings.symbols
    latest = latest_event_by_symbol(payload, symbols.values())
    missing = [symbol for symbol in symbols.values() if symbol not in latest]
    if missing:
        raise CollectorError("Missing dxFeed indicators: " + ", ".join(missing))

    values: dict[str, float] = {}
    times: dict[str, int] = {}
    for key, symbol in symbols.items():
        event = latest[symbol]
        value = event_price(event)
        ts = event_timestamp(event)
        if value is None or value < 0:
            raise CollectorError(f"Invalid non-negative volume for {symbol}")
        if ts <= 0:
            raise CollectorError(f"Invalid timestamp for {symbol}")
        values[key] = value
        times[key] = ts

    oldest = min(times.values())
    newest = max(times.values())
    age = max(0, now_ts - oldest)
    skew = newest - oldest
    if oldest > now_ts + 60:
        raise CollectorError("dxFeed component timestamp is in the future")
    if age > settings.max_event_age_seconds:
        raise CollectorError(
            f"dxFeed breadth stale: age={age}s max={settings.max_event_age_seconds}s"
        )
    if skew > settings.max_component_skew_seconds:
        raise CollectorError(
            f"dxFeed component skew too large: skew={skew}s max={settings.max_component_skew_seconds}s"
        )

    advancing = values["nyse_up"] + values["nasdaq_up"]
    declining = values["nyse_down"] + values["nasdaq_down"]
    if advancing <= 0 and declining <= 0:
        raise CollectorError("Directional volume is zero")

    return {
        "timestamp": now_ts,
        "provider_asof_ts": oldest,
        "advancing_volume": advancing,
        "declining_volume": declining,
        "source": settings.source,
        "universe": settings.universe,
        "provider": "dxFeed",
        "transport": "REST_POLL",
        "composite": True,
        "received_ts": now_ts,
        "component_skew_seconds": skew,
        "components": {
            "nyse": {
                "advancing_symbol": symbols["nyse_up"],
                "advancing_volume": values["nyse_up"],
                "advancing_ts": times["nyse_up"],
                "declining_symbol": symbols["nyse_down"],
                "declining_volume": values["nyse_down"],
                "declining_ts": times["nyse_down"],
            },
            "nasdaq": {
                "advancing_symbol": symbols["nasdaq_up"],
                "advancing_volume": values["nasdaq_up"],
                "advancing_ts": times["nasdaq_up"],
                "declining_symbol": symbols["nasdaq_down"],
                "declining_volume": values["nasdaq_down"],
                "declining_ts": times["nasdaq_down"],
            },
        },
    }



def source_state_from_cumulative(sample: dict[str, Any], observed_ts: int) -> dict[str, Any]:
    comp = sample["components"]
    return {
        "version": 1,
        "observed_ts": int(observed_ts),
        "provider_asof_ts": int(sample.get("provider_asof_ts", sample.get("timestamp", 0))),
        "cumulative": {
            "nyse_up": float(comp["nyse"]["advancing_volume"]),
            "nyse_down": float(comp["nyse"]["declining_volume"]),
            "nasdaq_up": float(comp["nasdaq"]["advancing_volume"]),
            "nasdaq_down": float(comp["nasdaq"]["declining_volume"]),
        },
    }


def derive_interval_sample(
    cumulative_sample: dict[str, Any],
    source_state: dict[str, Any],
    settings: Settings,
    *,
    observed_ts: int,
) -> tuple[dict[str, Any] | None, dict[str, Any], str]:
    """Convert dxFeed's session-cumulative breadth volumes into interval deltas.

    The installed ADVL sidecar accumulates each observation. Feeding it dxFeed's
    session totals directly would double-count the same volume on every poll.
    Therefore the collector persists a provider baseline and writes only the new
    advancing/declining volume since the previous valid poll.
    """
    current_state = source_state_from_cumulative(cumulative_sample, observed_ts)
    prev = source_state.get("cumulative") if isinstance(source_state, dict) else None
    prev_observed = int(source_state.get("observed_ts", 0) or 0) if isinstance(source_state, dict) else 0
    if not isinstance(prev, dict) or prev_observed <= 0:
        return None, current_state, "BASELINE_PRIMED"

    gap = max(0, observed_ts - prev_observed)
    if gap > settings.max_baseline_gap_seconds:
        return None, current_state, f"BASELINE_GAP_REPRIMED:{gap}s"

    keys = ("nyse_up", "nyse_down", "nasdaq_up", "nasdaq_down")
    current = current_state["cumulative"]
    try:
        deltas = {key: float(current[key]) - float(prev[key]) for key in keys}
    except (KeyError, TypeError, ValueError):
        return None, current_state, "BASELINE_INVALID_REPRIMED"

    # A provider/session reset produces lower cumulative values. Re-prime instead
    # of sending negative volume into Kronos.
    if any(delta < -1e-9 for delta in deltas.values()):
        return None, current_state, "SOURCE_RESET_REPRIMED"

    deltas = {key: max(0.0, value) for key, value in deltas.items()}
    advancing = deltas["nyse_up"] + deltas["nasdaq_up"]
    declining = deltas["nyse_down"] + deltas["nasdaq_down"]
    if advancing <= 0.0 and declining <= 0.0:
        return None, current_state, "NO_NEW_DIRECTIONAL_VOLUME"

    interval = {
        "timestamp": int(observed_ts),
        "provider_asof_ts": int(cumulative_sample.get("provider_asof_ts", 0)),
        "advancing_volume": advancing,
        "declining_volume": declining,
        "source": cumulative_sample["source"],
        "universe": cumulative_sample["universe"],
        "provider": cumulative_sample.get("provider", "dxFeed"),
        "transport": cumulative_sample.get("transport", "REST_POLL"),
        "composite": bool(cumulative_sample.get("composite", True)),
        "received_ts": int(observed_ts),
        "component_skew_seconds": int(cumulative_sample.get("component_skew_seconds", 0)),
        "interval_seconds": gap,
        "volume_semantics": "INTERVAL_DELTA_FROM_PROVIDER_CUMULATIVE",
        "components": {
            "nyse": {
                "advancing_symbol": cumulative_sample["components"]["nyse"]["advancing_symbol"],
                "advancing_volume": deltas["nyse_up"],
                "advancing_cumulative": current["nyse_up"],
                "declining_symbol": cumulative_sample["components"]["nyse"]["declining_symbol"],
                "declining_volume": deltas["nyse_down"],
                "declining_cumulative": current["nyse_down"],
            },
            "nasdaq": {
                "advancing_symbol": cumulative_sample["components"]["nasdaq"]["advancing_symbol"],
                "advancing_volume": deltas["nasdaq_up"],
                "advancing_cumulative": current["nasdaq_up"],
                "declining_symbol": cumulative_sample["components"]["nasdaq"]["declining_symbol"],
                "declining_volume": deltas["nasdaq_down"],
                "declining_cumulative": current["nasdaq_down"],
            },
        },
    }
    return interval, current_state, "INTERVAL_READY"

def append_history(settings: Settings, sample: dict[str, Any]) -> None:
    settings.history_dir.mkdir(parents=True, exist_ok=True)
    ts = int(sample["timestamp"])
    day = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y%m%d")
    path = settings.history_dir / f"dxfeed_breadth_{day}.ndjson"
    compact = {
        "timestamp": ts,
        "received_ts": int(sample.get("received_ts", 0)),
        "advancing_volume": float(sample["advancing_volume"]),
        "declining_volume": float(sample["declining_volume"]),
        "net_advancing_volume": float(sample["advancing_volume"]) - float(sample["declining_volume"]),
        "total_directional_volume": float(sample["advancing_volume"]) + float(sample["declining_volume"]),
        "source": sample["source"],
        "universe": sample["universe"],
        "component_skew_seconds": int(sample.get("component_skew_seconds", 0)),
        "components": sample.get("components", {}),
    }
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(compact, separators=(",", ":"), sort_keys=True) + "\n")


def log_event(settings: Settings, event: str, **fields: Any) -> None:
    record = {
        "ts": int(time.time()),
        "event": event,
        "version": VERSION,
        **fields,
    }
    line = json.dumps(record, separators=(",", ":"), sort_keys=True)
    print(line, flush=True)
    try:
        settings.log_dir.mkdir(parents=True, exist_ok=True)
        day = datetime.now(tz=timezone.utc).strftime("%Y%m%d")
        with (settings.log_dir / f"advl_dxfeed_{day}.log").open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass


def load_status(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
        return raw if isinstance(raw, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_status(settings: Settings, **fields: Any) -> None:
    prior = load_status(settings.status_path)
    payload = {
        "version": VERSION,
        "provider": "dxFeed",
        "mode": settings.mode,
        "source": settings.source,
        "universe": settings.universe,
        "rest_url": settings.rest_url,
        "updated_ts": int(time.time()),
        "last_success_ts": int(prior.get("last_success_ts", 0) or 0),
        "consecutive_failures": int(prior.get("consecutive_failures", 0) or 0),
        **fields,
    }
    _atomic_write_json(settings.status_path, payload)


def process_once(settings: Settings, *, validate_only: bool = False, now_ts: int | None = None) -> dict[str, Any]:
    now_ts = int(time.time()) if now_ts is None else int(now_ts)
    payload = request_snapshot(settings, now_ts=now_ts)
    cumulative = build_breadth_sample(payload, settings, now_ts=now_ts)

    source_state = load_status(settings.source_state_path)
    interval, next_source_state, conversion_reason = derive_interval_sample(
        cumulative,
        source_state,
        settings,
        observed_ts=now_ts,
    )

    may_write = settings.mode == "production" or settings.allow_demo_write
    if validate_only:
        may_write = False

    # Persist the provider baseline before publishing an interval. In the rare
    # event of a crash between these writes, we prefer to miss one confirmation
    # interval rather than duplicate volume and overstate ADVL.
    if may_write:
        _atomic_write_json(settings.source_state_path, next_source_state)

    if interval is None:
        write_status(
            settings,
            state="PRIMED" if conversion_reason == "BASELINE_PRIMED" else "WAITING",
            reason=conversion_reason,
            last_success_ts=now_ts,
            last_event_ts=int(cumulative.get("provider_asof_ts", 0)),
            consecutive_failures=0,
            feed_path=str(settings.feed_path),
        )
        log_event(
            settings,
            "cumulative_validated_no_interval",
            reason=conversion_reason,
            provider_asof_ts=int(cumulative.get("provider_asof_ts", 0)),
            mode=settings.mode,
        )
        return cumulative

    if may_write:
        prior_status = load_status(settings.status_path)
        last_key = str(prior_status.get("last_history_key", ""))
        history_key = (
            f"{interval['timestamp']}|{interval['advancing_volume']:.6f}|"
            f"{interval['declining_volume']:.6f}"
        )
        _atomic_write_json(settings.feed_path, interval)
        if history_key != last_key:
            append_history(settings, interval)
        write_status(
            settings,
            state="OK",
            reason="INTERVAL_SAMPLE_WRITTEN",
            last_success_ts=now_ts,
            last_event_ts=int(interval["provider_asof_ts"]),
            last_history_key=history_key,
            consecutive_failures=0,
            feed_path=str(settings.feed_path),
        )
        log_event(
            settings,
            "interval_written",
            event_ts=int(interval["timestamp"]),
            provider_asof_ts=int(interval["provider_asof_ts"]),
            advancing_volume=interval["advancing_volume"],
            declining_volume=interval["declining_volume"],
            interval_seconds=interval["interval_seconds"],
        )
        return interval

    write_status(
        settings,
        state="VALIDATED",
        reason="DEMO_OR_VALIDATE_ONLY_NO_PRODUCTION_WRITE",
        last_success_ts=now_ts,
        last_event_ts=int(interval["provider_asof_ts"]),
        consecutive_failures=0,
        feed_path=str(settings.feed_path),
    )
    log_event(
        settings,
        "interval_validated_no_write",
        event_ts=int(interval["timestamp"]),
        mode=settings.mode,
    )
    return interval

def run_forever(settings: Settings) -> None:
    log_event(
        settings,
        "collector_start",
        mode=settings.mode,
        poll_seconds=settings.poll_seconds,
        endpoint=settings.rest_url,
        symbols=settings.symbols,
    )
    while True:
        started = time.monotonic()
        try:
            process_once(settings)
        except Exception as exc:
            prior = load_status(settings.status_path)
            failures = int(prior.get("consecutive_failures", 0) or 0) + 1
            write_status(
                settings,
                state="ERROR",
                reason=str(exc)[:1000],
                consecutive_failures=failures,
            )
            log_event(settings, "collector_error", error=str(exc), consecutive_failures=failures)
        elapsed = time.monotonic() - started
        time.sleep(max(0.25, settings.poll_seconds - elapsed))


def synthetic_response(now_ts: int) -> dict[str, Any]:
    def event(symbol: str, value: float, age: int) -> dict[str, Any]:
        return {"eventSymbol": symbol, "price": value, "time": (now_ts - age) * 1000}

    return {
        "status": "OK",
        "TimeAndSale": {
            "$UVOLC": [event("$UVOLC", 1_100_000_000, 2)],
            "$DVOLC": [event("$DVOLC", 900_000_000, 2)],
            "$UVOLC/Q": [event("$UVOLC/Q", 1_500_000_000, 1)],
            "$DVOLC/Q": [event("$DVOLC/Q", 1_000_000_000, 1)],
        },
    }


def self_test(settings: Settings) -> None:
    now_ts = 1_800_000_000
    sample = build_breadth_sample(synthetic_response(now_ts), settings, now_ts=now_ts)
    assert sample["advancing_volume"] == 2_600_000_000
    assert sample["declining_volume"] == 1_900_000_000
    assert sample["timestamp"] == now_ts
    assert sample["provider_asof_ts"] == now_ts - 2
    assert sample["component_skew_seconds"] == 1
    baseline = source_state_from_cumulative(sample, now_ts)
    newer = synthetic_response(now_ts + 5)
    newer["TimeAndSale"]["$UVOLC"][0]["price"] += 100
    newer["TimeAndSale"]["$DVOLC"][0]["price"] += 40
    newer["TimeAndSale"]["$UVOLC/Q"][0]["price"] += 200
    newer["TimeAndSale"]["$DVOLC/Q"][0]["price"] += 60
    cumulative2 = build_breadth_sample(newer, settings, now_ts=now_ts + 5)
    interval, _, reason = derive_interval_sample(cumulative2, baseline, settings, observed_ts=now_ts + 5)
    assert reason == "INTERVAL_READY"
    assert interval is not None
    assert interval["advancing_volume"] == 300
    assert interval["declining_volume"] == 100
    print(json.dumps({"SELF_TEST": "PASS", "version": VERSION, "cumulative": sample, "interval": interval}, indent=2))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Abutron ADVL dxFeed breadth collector")
    parser.add_argument("--root", default=str(DEFAULT_ROOT))
    parser.add_argument("--env", default="")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = Path(args.root)
    env_path = Path(args.env) if args.env else None
    try:
        settings = build_settings(root, env_path)
        if args.self_test:
            self_test(settings)
            return 0
        if args.once or args.validate_only:
            sample = process_once(settings, validate_only=args.validate_only)
            print(json.dumps(sample, indent=2, sort_keys=True))
            return 0
        run_forever(settings)
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
