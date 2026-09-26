import os
import sys
import unittest
from pathlib import Path

# Allow this test to run directly from the extracted package on Windows/Linux.
PACKAGE_ROOT = Path(__file__).resolve().parents[1]
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

import advl  # noqa: E402


class TestADVL(unittest.TestCase):
    def setUp(self):
        self.now = 2_000_000_000

    def test_missing_or_invalid_feed_is_neutral(self):
        feature, state = advl.compute_advl_feature({}, {}, now_ts=self.now)
        self.assertFalse(feature.valid)
        self.assertEqual(feature.signal, 0.0)
        self.assertEqual(state, {})

    def test_stale_feed_is_neutral(self):
        feed = {
            "timestamp": self.now - 1000,
            "advancing_volume": 600,
            "declining_volume": 400,
            "source": "TEST",
            "universe": "NYSE",
        }
        feature, _ = advl.compute_advl_feature(feed, {}, now_ts=self.now, max_age_seconds=900)
        self.assertFalse(feature.valid)
        self.assertTrue(feature.stale)
        self.assertEqual(feature.reason, "STALE_DATA")
        self.assertEqual(feature.signal, 0.0)

    def test_cumulative_line_and_signal(self):
        state = {}
        for i in range(20):
            feed = {
                "timestamp": self.now - 60 * (19 - i),
                "advancing_volume": 700,
                "declining_volume": 300,
                "source": "TEST",
                "universe": "NYSE",
            }
            feature, state = advl.compute_advl_feature(
                feed,
                state,
                now_ts=self.now,
                lookback=20,
                max_age_seconds=3600,
            )
        self.assertTrue(feature.valid)
        self.assertGreater(feature.signal, 0.0)
        self.assertAlmostEqual(feature.advl_value, 8000.0)
        self.assertEqual(feature.samples, 20)
        self.assertGreater(feature.quality, 0.99)

    def test_negative_breadth_produces_negative_signal(self):
        state = {}
        for i in range(20):
            feed = {
                "timestamp": self.now - 60 * (19 - i),
                "advancing_volume": 250,
                "declining_volume": 750,
                "source": "TEST",
                "universe": "NYSE",
            }
            feature, state = advl.compute_advl_feature(
                feed,
                state,
                now_ts=self.now,
                lookback=20,
                max_age_seconds=3600,
            )
        self.assertTrue(feature.valid)
        self.assertLess(feature.signal, 0.0)
        self.assertAlmostEqual(feature.signal, -0.5)

    def test_duplicate_timestamp_does_not_double_count(self):
        feed = {
            "timestamp": self.now,
            "advancing_volume": 700,
            "declining_volume": 300,
            "source": "TEST",
            "universe": "NYSE",
        }
        f1, state = advl.compute_advl_feature(feed, {}, now_ts=self.now)
        f2, state2 = advl.compute_advl_feature(feed, state, now_ts=self.now)
        self.assertEqual(f1.advl_value, f2.advl_value)
        self.assertEqual(state["advl_value"], state2["advl_value"])

    def test_shadow_mode_never_changes_score(self):
        feature = advl.ADVLFeature(signal=1.0, quality=1.0, valid=True, stale=False)
        old = os.environ.get("ABUTRON_ADVL_MODE")
        os.environ["ABUTRON_ADVL_MODE"] = "shadow"
        try:
            score, applied = advl.blend_advl_confirmation(0.40, feature, "FUSION")
        finally:
            if old is None:
                os.environ.pop("ABUTRON_ADVL_MODE", None)
            else:
                os.environ["ABUTRON_ADVL_MODE"] = old
        self.assertFalse(applied)
        self.assertEqual(score, 0.40)

    def test_live_mode_requires_quality_and_never_modifies_kronos_only(self):
        good = advl.ADVLFeature(signal=1.0, quality=1.0, valid=True, stale=False)
        weak = advl.ADVLFeature(signal=1.0, quality=0.50, valid=True, stale=False)
        previous = {
            k: os.environ.get(k)
            for k in [
                "ABUTRON_ADVL_MODE",
                "ABUTRON_ADVL_FUSION_WEIGHT",
                "ABUTRON_ADVL_MIN_QUALITY",
            ]
        }
        os.environ["ABUTRON_ADVL_MODE"] = "live"
        os.environ["ABUTRON_ADVL_FUSION_WEIGHT"] = "0.05"
        os.environ["ABUTRON_ADVL_MIN_QUALITY"] = "0.75"
        try:
            fusion_score, fusion_applied = advl.blend_advl_confirmation(0.40, good, "FUSION")
            institutional_score, institutional_applied = advl.blend_advl_confirmation(0.40, good, "INSTITUTIONAL")
            kronos_score, kronos_applied = advl.blend_advl_confirmation(0.40, good, "KRONOS")
            weak_score, weak_applied = advl.blend_advl_confirmation(0.40, weak, "FUSION")
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.assertTrue(fusion_applied)
        self.assertAlmostEqual(fusion_score, 0.43)
        self.assertTrue(institutional_applied)
        self.assertAlmostEqual(institutional_score, 0.43)
        self.assertFalse(kronos_applied)
        self.assertEqual(kronos_score, 0.40)
        self.assertFalse(weak_applied)
        self.assertEqual(weak_score, 0.40)

    def test_weight_is_hard_capped_at_ten_percent(self):
        feature = advl.ADVLFeature(signal=1.0, quality=1.0, valid=True, stale=False)
        old_mode = os.environ.get("ABUTRON_ADVL_MODE")
        old_weight = os.environ.get("ABUTRON_ADVL_FUSION_WEIGHT")
        os.environ["ABUTRON_ADVL_MODE"] = "live"
        os.environ["ABUTRON_ADVL_FUSION_WEIGHT"] = "1.0"
        try:
            score, applied = advl.blend_advl_confirmation(0.0, feature, "FUSION")
        finally:
            if old_mode is None:
                os.environ.pop("ABUTRON_ADVL_MODE", None)
            else:
                os.environ["ABUTRON_ADVL_MODE"] = old_mode
            if old_weight is None:
                os.environ.pop("ABUTRON_ADVL_FUSION_WEIGHT", None)
            else:
                os.environ["ABUTRON_ADVL_FUSION_WEIGHT"] = old_weight
        self.assertTrue(applied)
        self.assertAlmostEqual(score, 0.10)

    def test_out_of_order_observation_is_neutral(self):
        newer = {
            "timestamp": self.now,
            "advancing_volume": 700,
            "declining_volume": 300,
            "source": "TEST",
            "universe": "NYSE",
        }
        _, state = advl.compute_advl_feature(newer, {}, now_ts=self.now)
        older = dict(newer, timestamp=self.now - 60)
        feature, state2 = advl.compute_advl_feature(older, state, now_ts=self.now)
        self.assertFalse(feature.valid)
        self.assertEqual(feature.reason, "OUT_OF_ORDER_DATA")
        self.assertEqual(state2["advl_value"], state["advl_value"])

    def test_universe_change_resets_cumulative_line(self):
        nyse = {
            "timestamp": self.now - 60,
            "advancing_volume": 700,
            "declining_volume": 300,
            "source": "TEST",
            "universe": "NYSE",
        }
        _, state = advl.compute_advl_feature(nyse, {}, now_ts=self.now, max_age_seconds=3600)
        nasdaq = dict(nyse, timestamp=self.now, universe="NASDAQ", advancing_volume=800, declining_volume=200)
        feature, state2 = advl.compute_advl_feature(nasdaq, state, now_ts=self.now, max_age_seconds=3600)
        self.assertTrue(feature.valid)
        self.assertEqual(feature.samples, 1)
        self.assertEqual(feature.advl_value, 600.0)
        self.assertEqual(state2["universe"], "NASDAQ")

    def test_weak_signal_does_not_dilute_live_fusion_score(self):
        feature = advl.ADVLFeature(signal=0.05, quality=1.0, valid=True, stale=False)
        old_mode = os.environ.get("ABUTRON_ADVL_MODE")
        old_min = os.environ.get("ABUTRON_ADVL_MIN_ABS_SIGNAL")
        os.environ["ABUTRON_ADVL_MODE"] = "live"
        os.environ["ABUTRON_ADVL_MIN_ABS_SIGNAL"] = "0.10"
        try:
            score, applied = advl.blend_advl_confirmation(0.40, feature, "FUSION")
        finally:
            if old_mode is None:
                os.environ.pop("ABUTRON_ADVL_MODE", None)
            else:
                os.environ["ABUTRON_ADVL_MODE"] = old_mode
            if old_min is None:
                os.environ.pop("ABUTRON_ADVL_MIN_ABS_SIGNAL", None)
            else:
                os.environ["ABUTRON_ADVL_MIN_ABS_SIGNAL"] = old_min
        self.assertFalse(applied)
        self.assertEqual(score, 0.40)

    def test_bad_environment_values_fail_to_safe_defaults(self):
        feature = advl.ADVLFeature(signal=1.0, quality=1.0, valid=True, stale=False)
        old = {k: os.environ.get(k) for k in [
            "ABUTRON_ADVL_MODE", "ABUTRON_ADVL_FUSION_WEIGHT",
            "ABUTRON_ADVL_MIN_QUALITY", "ABUTRON_ADVL_MIN_ABS_SIGNAL"
        ]}
        os.environ["ABUTRON_ADVL_MODE"] = "live"
        os.environ["ABUTRON_ADVL_FUSION_WEIGHT"] = "not-a-number"
        os.environ["ABUTRON_ADVL_MIN_QUALITY"] = "bad"
        os.environ["ABUTRON_ADVL_MIN_ABS_SIGNAL"] = "bad"
        try:
            score, applied = advl.blend_advl_confirmation(0.40, feature, "FUSION")
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.assertTrue(applied)
        self.assertAlmostEqual(score, 0.43)

    def test_future_timestamp_is_neutral(self):
        feed = {
            "timestamp": self.now + 120,
            "advancing_volume": 600,
            "declining_volume": 400,
            "source": "TEST",
            "universe": "NYSE",
        }
        feature, state = advl.compute_advl_feature(feed, {}, now_ts=self.now)
        self.assertFalse(feature.valid)
        self.assertEqual(feature.reason, "FUTURE_TIMESTAMP")
        self.assertEqual(state, {})

    def test_negative_volume_is_rejected_not_clamped(self):
        feed = {
            "timestamp": self.now,
            "advancing_volume": -1,
            "declining_volume": 400,
            "source": "TEST",
            "universe": "NYSE",
        }
        feature, state = advl.compute_advl_feature(feed, {}, now_ts=self.now)
        self.assertFalse(feature.valid)
        self.assertEqual(feature.reason, "NEGATIVE_VOLUME")
        self.assertEqual(state, {})

    def test_millisecond_epoch_is_normalized(self):
        feed = {
            "timestamp": self.now * 1000,
            "advancing_volume": 600,
            "declining_volume": 400,
            "source": "TEST",
            "universe": "NYSE",
        }
        feature, _ = advl.compute_advl_feature(feed, {}, now_ts=self.now)
        self.assertTrue(feature.valid)
        self.assertEqual(feature.asof_ts, self.now)


if __name__ == "__main__":
    unittest.main()
