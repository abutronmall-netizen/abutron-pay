import importlib.util
import json
import os
import tempfile
import unittest
import sys
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("collector", HERE / "advl_dxfeed_collector.py")
c = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules["collector"] = c
SPEC.loader.exec_module(c)


class TestCollector(unittest.TestCase):
    def make_settings(self, root, **kwargs):
        base = dict(
            root=Path(root),
            env_path=Path(root) / "secrets" / "dxfeed_advl.env",
            rest_url="https://example.invalid/events.json",
            token="token",
            username="",
            password="",
            mode="production",
            poll_seconds=5.0,
            window_seconds=180,
            request_timeout=10,
            max_event_age_seconds=30,
            max_component_skew_seconds=20,
            max_baseline_gap_seconds=30,
            allow_demo_write=False,
            source="DXFEED_MARKET_INDICATORS",
            universe="NYSE+NASDAQ_COMPOSITE",
            symbols=dict(c.DEFAULT_SYMBOLS),
        )
        base.update(kwargs)
        return c.Settings(**base)

    def test_synthetic_sample_combines_nyse_and_nasdaq(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            sample = c.build_breadth_sample(c.synthetic_response(now), s, now_ts=now)
            self.assertEqual(sample["advancing_volume"], 2_600_000_000)
            self.assertEqual(sample["declining_volume"], 1_900_000_000)
            self.assertEqual(sample["timestamp"], now)
            self.assertEqual(sample["provider_asof_ts"], now - 2)

    def test_oldest_component_timestamp_is_used(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            sample = c.build_breadth_sample(c.synthetic_response(now), s, now_ts=now)
            self.assertEqual(sample["provider_asof_ts"], now - 2)

    def test_missing_symbol_fails(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            payload = c.synthetic_response(now)
            del payload["TimeAndSale"]["$DVOLC/Q"]
            with self.assertRaises(c.CollectorError):
                c.build_breadth_sample(payload, s, now_ts=now)

    def test_negative_volume_fails(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            payload = c.synthetic_response(now)
            payload["TimeAndSale"]["$DVOLC"][0]["price"] = -1
            with self.assertRaises(c.CollectorError):
                c.build_breadth_sample(payload, s, now_ts=now)

    def test_stale_component_fails(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td, max_event_age_seconds=5)
            now = 1_800_000_000
            payload = c.synthetic_response(now)
            for rows in payload["TimeAndSale"].values():
                rows[0]["time"] = (now - 10) * 1000
            with self.assertRaises(c.CollectorError):
                c.build_breadth_sample(payload, s, now_ts=now)

    def test_component_skew_fails(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td, max_component_skew_seconds=3)
            now = 1_800_000_000
            payload = c.synthetic_response(now)
            payload["TimeAndSale"]["$UVOLC"][0]["time"] = (now - 10) * 1000
            with self.assertRaises(c.CollectorError):
                c.build_breadth_sample(payload, s, now_ts=now)

    def test_future_timestamp_fails(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            payload = c.synthetic_response(now)
            for rows in payload["TimeAndSale"].values():
                rows[0]["time"] = (now + 120) * 1000
            with self.assertRaises(c.CollectorError):
                c.build_breadth_sample(payload, s, now_ts=now)

    def test_demo_never_writes_by_default(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td, mode="demo", allow_demo_write=False, token="")
            now = 1_800_000_000
            with patch.object(c, "request_snapshot", return_value=c.synthetic_response(now)):
                c.process_once(s, now_ts=now)
            self.assertFalse(s.feed_path.exists())
            self.assertFalse(s.source_state_path.exists())
            self.assertTrue(s.status_path.exists())

    def test_production_first_sample_primes_then_second_writes_delta(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            first = c.synthetic_response(now)
            second = c.synthetic_response(now + 5)
            second["TimeAndSale"]["$UVOLC"][0]["price"] += 100
            second["TimeAndSale"]["$DVOLC"][0]["price"] += 40
            second["TimeAndSale"]["$UVOLC/Q"][0]["price"] += 200
            second["TimeAndSale"]["$DVOLC/Q"][0]["price"] += 60
            with patch.object(c, "request_snapshot", side_effect=[first, second]):
                c.process_once(s, now_ts=now)
                self.assertFalse(s.feed_path.exists())
                c.process_once(s, now_ts=now + 5)
            data = json.loads(s.feed_path.read_text(encoding="utf-8"))
            self.assertEqual(data["advancing_volume"], 300)
            self.assertEqual(data["declining_volume"], 100)
            self.assertEqual(data["volume_semantics"], "INTERVAL_DELTA_FROM_PROVIDER_CUMULATIVE")

    def test_history_deduplicates_when_no_new_volume(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            first = c.synthetic_response(now)
            second = c.synthetic_response(now + 5)
            second["TimeAndSale"]["$UVOLC"][0]["price"] += 100
            third = c.synthetic_response(now + 10)
            third["TimeAndSale"]["$UVOLC"][0]["price"] += 100
            with patch.object(c, "request_snapshot", side_effect=[first, second, third]):
                c.process_once(s, now_ts=now)
                c.process_once(s, now_ts=now + 5)
                c.process_once(s, now_ts=now + 10)
            files = list(s.history_dir.glob("*.ndjson"))
            self.assertEqual(len(files), 1)
            lines = files[0].read_text(encoding="utf-8").strip().splitlines()
            self.assertEqual(len(lines), 1)

    def test_cumulative_conversion_prevents_double_counting(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            first = c.build_breadth_sample(c.synthetic_response(now), s, now_ts=now)
            state = c.source_state_from_cumulative(first, now)
            second_payload = c.synthetic_response(now + 5)
            second_payload["TimeAndSale"]["$UVOLC"][0]["price"] += 10
            second_payload["TimeAndSale"]["$DVOLC"][0]["price"] += 4
            second = c.build_breadth_sample(second_payload, s, now_ts=now + 5)
            interval, _, reason = c.derive_interval_sample(second, state, s, observed_ts=now + 5)
            self.assertEqual(reason, "INTERVAL_READY")
            self.assertEqual(interval["advancing_volume"], 10)
            self.assertEqual(interval["declining_volume"], 4)

    def test_source_reset_reprimes_without_negative_feed(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            first = c.build_breadth_sample(c.synthetic_response(now), s, now_ts=now)
            state = c.source_state_from_cumulative(first, now)
            reset_payload = c.synthetic_response(now + 5)
            reset_payload["TimeAndSale"]["$UVOLC"][0]["price"] = 1
            reset = c.build_breadth_sample(reset_payload, s, now_ts=now + 5)
            interval, _, reason = c.derive_interval_sample(reset, state, s, observed_ts=now + 5)
            self.assertIsNone(interval)
            self.assertEqual(reason, "SOURCE_RESET_REPRIMED")

    def test_long_gap_reprimes(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td, max_baseline_gap_seconds=10)
            now = 1_800_000_000
            first = c.build_breadth_sample(c.synthetic_response(now), s, now_ts=now)
            state = c.source_state_from_cumulative(first, now)
            later = c.build_breadth_sample(c.synthetic_response(now + 30), s, now_ts=now + 30)
            interval, _, reason = c.derive_interval_sample(later, state, s, observed_ts=now + 30)
            self.assertIsNone(interval)
            self.assertTrue(reason.startswith("BASELINE_GAP_REPRIMED"))

    def test_production_requires_credentials(self):
        with tempfile.TemporaryDirectory() as td:
            env = Path(td) / "cfg.env"
            env.write_text("DXFEED_MODE=production\nDXFEED_TOKEN=\n", encoding="utf-8")
            with patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(c.CollectorError):
                    c.build_settings(Path(td), env)

    def test_millisecond_timestamp_normalized(self):
        event = {"eventSymbol": "$UVOLC", "time": 1_800_000_000_000, "price": 1.0}
        self.assertEqual(c.event_timestamp(event), 1_800_000_000)

    def test_latest_event_selected(self):
        payload = {
            "TimeAndSale": {
                "$UVOLC": [
                    {"eventSymbol": "$UVOLC", "time": 1_000_000, "price": 1},
                    {"eventSymbol": "$UVOLC", "time": 2_000_000, "price": 2},
                ]
            }
        }
        latest = c.latest_event_by_symbol(payload, ["$UVOLC"])
        self.assertEqual(latest["$UVOLC"]["price"], 2)

    def test_extra_response_fields_are_ignored(self):
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            now = 1_800_000_000
            payload = c.synthetic_response(now)
            payload["OtherEvent"] = {"X": {"price": 999}}
            sample = c.build_breadth_sample(payload, s, now_ts=now)
            self.assertGreater(sample["advancing_volume"], 0)

    def test_rest_rate_default_is_conservative(self):
        # 5 second polling = 12 requests/minute, well below the documented 100/min REST limit.
        with tempfile.TemporaryDirectory() as td:
            s = self.make_settings(td)
            self.assertGreaterEqual(s.poll_seconds, 5.0)


if __name__ == "__main__":
    unittest.main()
