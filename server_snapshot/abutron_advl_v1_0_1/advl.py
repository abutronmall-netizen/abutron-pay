from __future__ import annotations

import json
import math
import os
import tempfile
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path(os.getenv("ABUTRON_ROOT", r"C:\Abutron\TradingPlatformV4"))
DEFAULT_FEED = DEFAULT_ROOT / "runtime" / "advl_breadth.json"
DEFAULT_STATE = DEFAULT_ROOT / "runtime" / "advl_state.json"


@dataclass(frozen=True)
class ADVLFeature:
    signal: float = 0.0
    quality: float = 0.0
    advl_value: float = 0.0
    net_advancing_volume: float = 0.0
    total_directional_volume: float = 0.0
    asof_ts: int = 0
    age_seconds: int = 0
    source: str = "NONE"
    universe: str = "UNKNOWN"
    valid: bool = False
    stale: bool = True
    reason: str = "NO_DATA"
    samples: int = 0
    applied: bool = False

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, float(value)))


def _normalize_epoch(value: float) -> int:
    result = float(value)
    # Common APIs emit milliseconds or microseconds; normalize to seconds.
    while abs(result) > 10_000_000_000:
        result /= 1000.0
    return int(result)


def _parse_ts(value: Any) -> int:
    if value is None:
        return 0
    if isinstance(value, (int, float)):
        return _normalize_epoch(float(value))
    text = str(value).strip()
    if not text:
        return 0
    try:
        return _normalize_epoch(float(text))
    except ValueError:
        pass
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp())
    except ValueError:
        return 0


def _safe_float(value: Any) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return 0.0
    return result if math.isfinite(result) else 0.0


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if raw is None:
        return float(default)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return float(default)
    return value if math.isfinite(value) else float(default)


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return int(default)
    try:
        return int(raw)
    except (TypeError, ValueError):
        return int(default)


def _load_json(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8-sig"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)
        except OSError:
            pass


def _feed_values(payload: dict[str, Any]) -> tuple[int, float, float, str, str]:
    ts = _parse_ts(payload.get("timestamp", payload.get("asof_ts", payload.get("ts"))))
    up = _safe_float(payload.get("advancing_volume", payload.get("up_volume")))
    down = _safe_float(payload.get("declining_volume", payload.get("down_volume")))
    source = str(payload.get("source", "UNKNOWN")).strip() or "UNKNOWN"
    universe = str(payload.get("universe", "UNKNOWN")).strip() or "UNKNOWN"
    return ts, up, down, source, universe


def _empty(reason: str, *, source: str = "NONE", universe: str = "UNKNOWN", age: int = 0) -> ADVLFeature:
    return ADVLFeature(source=source, universe=universe, reason=reason, age_seconds=max(0, age))


def compute_advl_feature(
    feed_payload: dict[str, Any],
    state_payload: dict[str, Any] | None = None,
    *,
    now_ts: int | None = None,
    lookback: int = 20,
    max_age_seconds: int = 900,
) -> tuple[ADVLFeature, dict[str, Any]]:
    """Compute a cumulative Advance/Decline Volume Line feature.

    The feed must contain exchange/universe breadth data, not a single instrument's
    candle volume. Expected fields are timestamp, advancing_volume,
    declining_volume, source and universe.
    """
    now = int(time.time()) if now_ts is None else int(now_ts)
    lookback = max(3, min(int(lookback), 200))
    max_age_seconds = max(1, int(max_age_seconds))
    state = dict(state_payload or {})

    ts, up, down, source, universe = _feed_values(feed_payload)
    if ts <= 0:
        return _empty("INVALID_TIMESTAMP", source=source, universe=universe), state
    if ts > now + 60:
        return _empty("FUTURE_TIMESTAMP", source=source, universe=universe), state
    if up < 0.0 or down < 0.0:
        return _empty("NEGATIVE_VOLUME", source=source, universe=universe), state
    if up <= 0.0 and down <= 0.0:
        return _empty("NO_DIRECTIONAL_VOLUME", source=source, universe=universe), state

    age = max(0, now - ts)
    if age > max_age_seconds:
        return _empty("STALE_DATA", source=source, universe=universe, age=age), state

    total = up + down
    net = up - down
    previous_ts = _parse_ts(state.get("last_source_ts"))

    # Never mix different breadth universes/providers into one cumulative line.
    state_source = str(state.get("source", "")).strip()
    state_universe = str(state.get("universe", "")).strip()
    if previous_ts > 0 and (
        (state_source and state_source != source)
        or (state_universe and state_universe != universe)
    ):
        state = {}
        previous_ts = 0

    if previous_ts > 0 and ts < previous_ts:
        return _empty("OUT_OF_ORDER_DATA", source=source, universe=universe, age=age), state

    advl_value = _safe_float(state.get("advl_value"))
    history_raw = state.get("history", [])
    history = [x for x in history_raw if isinstance(x, dict)] if isinstance(history_raw, list) else []

    # Update cumulative ADVL only once for each new breadth observation.
    if ts > previous_ts:
        advl_value += net
        history.append(
            {
                "ts": ts,
                "advl": advl_value,
                "net": net,
                "total": total,
            }
        )
        history = history[-lookback:]
        state = {
            "version": 1,
            "last_source_ts": ts,
            "advl_value": advl_value,
            "source": source,
            "universe": universe,
            "history": history,
        }
    elif ts == previous_ts and not history:
        # Recover a usable state if the state file was partially written/cleared.
        advl_value += net
        history = [{"ts": ts, "advl": advl_value, "net": net, "total": total}]
        state.update(
            {
                "version": 1,
                "last_source_ts": ts,
                "advl_value": advl_value,
                "source": source,
                "universe": universe,
                "history": history,
            }
        )

    if not history:
        return _empty("NO_HISTORY", source=source, universe=universe, age=age), state

    # Normalize the recent change in cumulative ADVL by the directional volume
    # observed over the same window. This creates a bounded [-1, 1] confirmation
    # feature without pretending the absolute cumulative level is comparable
    # across exchanges or time periods.
    if len(history) == 1:
        denom = max(_safe_float(history[-1].get("total")), 1e-12)
        signal = _safe_float(history[-1].get("net")) / denom
    else:
        delta_advl = _safe_float(history[-1].get("advl")) - _safe_float(history[0].get("advl"))
        denom = sum(max(0.0, _safe_float(row.get("total"))) for row in history[1:])
        signal = delta_advl / max(denom, 1e-12)

    signal = _clamp(signal, -1.0, 1.0)
    sample_quality = _clamp(len(history) / float(lookback), 0.0, 1.0)
    freshness_quality = _clamp(1.0 - (age / float(max_age_seconds)), 0.0, 1.0)
    quality = _clamp(sample_quality * freshness_quality, 0.0, 1.0)

    return (
        ADVLFeature(
            signal=signal,
            quality=quality,
            advl_value=advl_value,
            net_advancing_volume=net,
            total_directional_volume=total,
            asof_ts=ts,
            age_seconds=age,
            source=source,
            universe=universe,
            valid=True,
            stale=False,
            reason="OK",
            samples=len(history),
        ),
        state,
    )


def get_advl_feature() -> ADVLFeature:
    """Load the current breadth observation and fail neutral on any sidecar error."""
    try:
        feed_path = Path(os.getenv("ABUTRON_ADVL_FILE", str(DEFAULT_FEED)))
        state_path = Path(os.getenv("ABUTRON_ADVL_STATE_FILE", str(DEFAULT_STATE)))
        lookback = _env_int("ABUTRON_ADVL_LOOKBACK", 20)
        max_age = _env_int("ABUTRON_ADVL_MAX_AGE_SECONDS", 900)

        feed = _load_json(feed_path)
        if not feed:
            return _empty("FEED_MISSING")

        state = _load_json(state_path)
        feature, updated_state = compute_advl_feature(
            feed,
            state,
            lookback=lookback,
            max_age_seconds=max_age,
        )

        if feature.valid and updated_state != state:
            try:
                _atomic_write_json(state_path, updated_state)
            except OSError:
                return ADVLFeature(
                    **{**feature.as_dict(), "valid": False, "reason": "STATE_WRITE_FAILED"}
                )
        return feature
    except Exception:
        # ADVL is a confirmation sidecar. It must never crash the trading core.
        return _empty("ADVL_INTERNAL_ERROR")


def blend_advl_confirmation(score: float, feature: ADVLFeature, core_mode: Any) -> tuple[float, bool]:
    """Blend ADVL into Fusion/Institutional only when explicitly enabled.

    Default mode is SHADOW: data is calculated/logged but cannot alter decisions.
    """
    mode = str(os.getenv("ABUTRON_ADVL_MODE", "shadow")).strip().upper()
    if mode != "LIVE":
        return float(score), False

    core_mode_name = str(getattr(core_mode, "value", core_mode)).strip().upper()
    if core_mode_name not in {"FUSION", "INSTITUTIONAL"}:
        return float(score), False

    min_quality = _clamp(_env_float("ABUTRON_ADVL_MIN_QUALITY", 0.75), 0.0, 1.0)
    min_abs_signal = _clamp(_env_float("ABUTRON_ADVL_MIN_ABS_SIGNAL", 0.10), 0.0, 1.0)
    if (
        not feature.valid
        or feature.stale
        or feature.quality < min_quality
        or abs(feature.signal) < min_abs_signal
    ):
        return float(score), False

    weight = _clamp(_env_float("ABUTRON_ADVL_FUSION_WEIGHT", 0.05), 0.0, 0.10)
    if weight <= 0.0:
        return float(score), False

    blended = ((1.0 - weight) * float(score)) + (weight * feature.signal)
    return _clamp(blended, -1.0, 1.0), True

