"""Tests for the CodexBar → AI Sphere normaliser. Run: /usr/bin/python3 -m unittest discover -s mac/tests"""
import datetime as dt
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import aisphere_sync as sync  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "codexbar-2026-11-11.json")
NOW = dt.datetime(2026, 11, 11, 10, 20, tzinfo=dt.timezone.utc)


def load_fixture():
    with open(FIXTURE, encoding="utf-8") as fh:
        return json.load(fh)


def by_id(payload):
    return {p["id"]: p for p in payload["p"]}


class NormaliseRealOutput(unittest.TestCase):
    def setUp(self):
        self.payload = sync.normalise(load_fixture(), dict(sync.DEFAULTS), now=NOW)
        self.providers = by_id(self.payload)

    def test_envelope(self):
        self.assertEqual(self.payload["v"], 1)
        self.assertEqual(self.payload["t"], "2026-11-11T10:20:00Z")
        self.assertEqual(list(self.providers), ["codex", "claude", "opencodego", "antigravity", "helmcode"])

    def test_no_personal_data_leaks(self):
        text = sync.to_bytes(self.payload).decode("utf-8")
        for needle in ("@", "example.com", "Example Org", "Example Plan", "example-plan", "Dashboard session", "credit"):
            self.assertNotIn(needle, text)

    def test_payload_is_small(self):
        self.assertLess(len(sync.to_bytes(self.payload)), 2048)

    def test_codex_weekly_with_pace(self):
        codex = self.providers["codex"]
        self.assertEqual(codex["n"], "CODEX")
        self.assertEqual(codex["w"], [{
            "l": "WK", "u": 99, "r": "2026-11-11T10:31:15Z", "m": 10080, "pc": {"e": 100, "ok": True},
        }])

    def test_claude_has_no_five_hour_window(self):
        labels = [w["l"] for w in self.providers["claude"]["w"]]
        self.assertEqual(labels, ["WK", "FABLE WK"])
        self.assertEqual(self.providers["claude"]["w"][0]["pc"], {"e": 91, "ok": True})
        self.assertNotIn("pc", self.providers["claude"]["w"][1])

    def test_antigravity_drops_duplicates_and_labels_groups(self):
        windows = self.providers["antigravity"]["w"]
        self.assertEqual(len(windows), 3)  # capped from 5 extras (2 duplicates removed)
        self.assertEqual([w["l"] for w in windows], ["GEM 5H", "C/G 5H", "GEM WK"])

    def test_helmcode_rounds_and_labels_models(self):
        windows = self.providers["helmcode"]["w"]
        self.assertEqual([(w["l"], w["u"]) for w in windows], [("GLM53", 100), ("DEEPSE", 14), ("QWEN38", 9)])
        self.assertTrue(all("m" not in w for w in windows))

    def test_opencodego_three_windows(self):
        self.assertEqual([w["l"] for w in self.providers["opencodego"]["w"]], ["5H", "WK", "MO"])


class Labels(unittest.TestCase):
    def test_durations(self):
        self.assertEqual(sync.duration_label(300), "5H")
        self.assertEqual(sync.duration_label(10080), "WK")
        self.assertEqual(sync.duration_label(43200), "MO")
        self.assertEqual(sync.duration_label(120), "2H")
        self.assertEqual(sync.duration_label(None), "")

    def test_groups(self):
        self.assertEqual(sync.window_label("Weekly", 10080), "WK")
        self.assertEqual(sync.window_label("Claude/GPT weekly", 10080), "C/G WK")
        self.assertEqual(sync.window_label("Gemini 4 Argon weekly", 10080), "ARGON WK")
        self.assertEqual(sync.window_label("Model quota", None, "glm5.3-flash · 1 / 2 tokens"), "GLM53")

    def test_helmcode_credits_plugin(self):
        # Shape CodexBar should give for mac/codexbar-plugins/helmcode-credits.js
        raw = [{"provider": "helmcode-credits", "rateWindowLabels": {"primary": "Credits"}, "usage": {
            "primary": {"usedPercent": 27.5, "resetsAt": "2026-12-01T00:00:00Z", "windowMinutes": 44640}}}]
        payload = sync.normalise(raw, dict(sync.DEFAULTS), now=NOW)
        public = json.loads(sync.to_bytes(payload))
        self.assertEqual(public["p"], [{"id": "helmcode-credits", "n": "HELM", "w": [
            {"l": "MO", "u": 28, "r": "2026-12-01T00:00:00Z", "m": 44640}]}])

    def test_plugin_fetch_snapshot_becomes_provider(self):
        # Real output of `codexbar plugins fetch helmcode-credits --json` on 2026-11-11
        snapshot = {"primary": {"usedPercent": 0, "windowMinutes": 44640, "title": "Credits",
                                "resetsAt": "2026-12-01T00:00:00Z"},
                    "updatedAt": "2026-11-11T11:29:53Z", "secondary": None, "dataConfidence": "exact",
                    "tertiary": None, "details": [{"rows": [{"label": "Used", "value": "0 / 5000"}],
                                                   "title": "Monthly credits"}]}
        entry = sync.plugin_entry("helmcode-credits", snapshot)
        payload = sync.normalise([entry], dict(sync.DEFAULTS), now=NOW)
        public = json.loads(sync.to_bytes(payload))
        self.assertEqual(public["p"], [{"id": "helmcode-credits", "n": "HELM", "w": [
            {"l": "MO", "u": 0, "r": "2026-12-01T00:00:00Z", "m": 44640}]}])
        self.assertIsNone(sync.plugin_entry("x", {"error": "denied"}))

    def test_override(self):
        cfg = dict(sync.DEFAULTS, labels={"helmcode/helmcode-deepseek-v4-flash": "DSV4"})
        payload = sync.normalise(load_fixture(), cfg, now=NOW)
        self.assertIn("DSV4", [w["l"] for w in by_id(payload)["helmcode"]["w"]])


class Robustness(unittest.TestCase):
    def test_failed_provider_keeps_previous_values_flagged(self):
        previous = {"v": 1, "t": "x", "p": [{"id": "claude", "n": "CLAUDE", "w": [{"l": "WK", "u": 40}]}]}
        raw = [{"provider": "claude", "error": {"message": "timeout"}}]
        payload = sync.normalise(raw, dict(sync.DEFAULTS), previous, now=NOW)
        public = json.loads(sync.to_bytes(payload))
        self.assertEqual(public["p"], [{"id": "claude", "n": "CLAUDE", "w": [{"l": "WK", "u": 40}], "err": 1}])

    def _previous(self, seen_hours_ago):
        seen = int(NOW.timestamp()) - int(seen_hours_ago * 3600)
        return {"v": 1, "t": "2026-11-11T10:00:00Z", "p": [
            {"id": "codex", "n": "CODEX", "w": [{"l": "WK", "u": 10}], "_seen": seen},
            {"id": "opencodego", "n": "OC GO", "w": [{"l": "5H", "u": 0}], "_seen": seen},
            {"id": "claude", "n": "CLAUDE", "w": [{"l": "WK", "u": 27}], "_seen": seen},
        ]}

    def test_missing_provider_kept_in_place_during_grace(self):
        raw = [p for p in load_fixture() if p["provider"] in ("codex", "claude")]
        payload = sync.normalise(raw, dict(sync.DEFAULTS), self._previous(2), now=NOW)
        self.assertEqual([p["id"] for p in payload["p"]], ["codex", "opencodego", "claude"])
        ocgo = payload["p"][1]
        self.assertEqual(ocgo["err"], 1)
        self.assertEqual(ocgo["w"], [{"l": "5H", "u": 0}])
        # The fresh ones get a new _seen; the missing one keeps its old one.
        self.assertEqual(payload["p"][0]["_seen"], int(NOW.timestamp()))
        self.assertLess(ocgo["_seen"], int(NOW.timestamp()))

    def test_missing_provider_removed_after_grace(self):
        raw = [p for p in load_fixture() if p["provider"] in ("codex", "claude")]
        payload = sync.normalise(raw, dict(sync.DEFAULTS), self._previous(25), now=NOW)
        self.assertEqual([p["id"] for p in payload["p"]], ["codex", "claude"])

    def test_disabled_provider_removed_at_once(self):
        raw = [p for p in load_fixture() if p["provider"] in ("codex", "claude")]
        cfg = dict(sync.DEFAULTS, _disabled=["opencodego"])
        payload = sync.normalise(raw, cfg, self._previous(1), now=NOW)
        self.assertEqual([p["id"] for p in payload["p"]], ["codex", "claude"])

    def test_internal_keys_not_published(self):
        payload = sync.normalise(load_fixture(), dict(sync.DEFAULTS), now=NOW)
        self.assertIn("_seen", payload["p"][0])
        self.assertNotIn("_seen", sync.to_bytes(payload).decode("utf-8"))
        self.assertIn("_seen", sync.to_bytes(payload, public=False).decode("utf-8"))

    def test_failed_provider_without_history_is_left_out(self):
        payload = sync.normalise([{"provider": "x", "usage": None}], dict(sync.DEFAULTS), now=NOW)
        self.assertEqual(payload["p"], [])

    def test_exclude_and_names(self):
        cfg = dict(sync.DEFAULTS, exclude=["helmcode"], names={"codex": "CDX"})
        payload = sync.normalise(load_fixture(), cfg, now=NOW)
        ids = by_id(payload)
        self.assertNotIn("helmcode", ids)
        self.assertEqual(ids["codex"]["n"], "CDX")

    def test_percent_and_dates(self):
        self.assertEqual(sync.clamp_percent(13.7), 14)
        self.assertEqual(sync.clamp_percent(-3), 0)
        self.assertEqual(sync.clamp_percent(140), 100)
        self.assertIsNone(sync.clamp_percent("n/a"))
        self.assertEqual(sync.iso_utc("2026-11-12T00:59:59.123456789Z"), "2026-11-12T00:59:59Z")
        self.assertEqual(sync.iso_utc("2026-11-12T01:59:59+01:00"), "2026-11-12T00:59:59Z")
        self.assertIsNone(sync.iso_utc("mañana"))

    def test_pace_runs_out(self):
        self.assertEqual(sync.pace_block({"expectedUsedPercent": 58, "willLastToReset": False, "etaSeconds": 3600.4}),
                         {"e": 58, "ok": False, "eta": 3600})
        self.assertIsNone(sync.pace_block({"stage": "onTrack"}))

    def test_rejects_non_list(self):
        with self.assertRaises(ValueError):
            sync.normalise({"oops": True}, dict(sync.DEFAULTS), now=NOW)



class LabelLanguage(unittest.TestCase):
    def test_spanish_words(self):
        self.assertEqual(sync.duration_label(10080, "es"), "SEM")
        self.assertEqual(sync.duration_label(43200, "es"), "MES")
        self.assertEqual(sync.duration_label(1440, "es"), "DÍA")
        self.assertEqual(sync.window_label("Claude/GPT weekly", 10080, lang="es"), "C/G SEM")

    def test_setting_applies_to_payload(self):
        config = dict(sync.DEFAULTS, labelLanguage="es")
        payload = sync.normalise(load_fixture(), config, now=NOW)
        labels = [w["l"] for w in by_id(payload)["claude"]["w"]]
        self.assertEqual(labels, ["SEM", "FABLE SEM"])

    def test_unknown_language_falls_back_to_english(self):
        self.assertEqual(sync.duration_label(10080, "xx"), "WK")

if __name__ == "__main__":
    unittest.main()


class Hardening(unittest.TestCase):
    """Odd or hostile CodexBar data must not stop the publication or leak free text (security review)."""

    def entry(self, provider="codex", **usage):
        return {"provider": provider, "usage": usage, "rateWindowLabels": {}}

    def test_infinite_and_odd_values_do_not_abort(self):
        raw = json.loads('[{"provider": "codex", "usage": {"primary": {"usedPercent": 1e999, "windowMinutes": 1e999}}},'
                         ' {"provider": "claude", "usage": {"primary": {"usedPercent": 10, "windowMinutes": [1]},'
                         '  "extraRateWindows": [{"id": "x", "window": {"usedPercent": 5, "windowMinutes": {"a": 1}}}]},'
                         '  "rateWindowLabels": "not a dict", "pace": ["x"]},'
                         ' {"provider": "antigravity", "usage": {"primary": {"usedPercent": 20, "windowMinutes": 300}}}]')
        payload = sync.normalise(raw, dict(sync.DEFAULTS), now=NOW)
        ids = [p["id"] for p in payload["p"]]
        self.assertIn("antigravity", ids)
        self.assertIn("claude", ids)
        self.assertNotIn("codex", ids)  # infinite usage is not a usable window
        claude = by_id(payload)["claude"]["w"]
        self.assertTrue(all("m" not in w for w in claude))

    def test_unexpected_provider_ids_are_skipped(self):
        raw = [self.entry("john.doe@example.com personal", primary={"usedPercent": 1}),
               self.entry("x" * 40, primary={"usedPercent": 1}),
               self.entry("helmcode-credits", primary={"usedPercent": 1})]
        ids = [p["id"] for p in sync.normalise(raw, dict(sync.DEFAULTS), now=NOW)["p"]]
        self.assertEqual(ids, ["helmcode-credits"])

    def test_reset_description_free_text_is_not_published(self):
        self.assertEqual(sync.window_label("Model quota", None, "jdoe@example.com · 1/2"), "?")
        self.assertEqual(sync.window_label("Model quota", None, "Your plan renews soon · x"), "?")
        self.assertEqual(sync.window_label("Model quota", None, "glm5.3-flash · 1/2 tokens"), "GLM53")

    def test_jwt_with_odd_body(self):
        import base64
        body = base64.urlsafe_b64encode(b'["not", "an", "object"]').decode().rstrip("=")
        self.assertIsNone(sync.jwt_expiry(f"eyJhbGciOiJIUzI1NiJ9.{body}.c2ln"))

    def test_plugin_secrets_only_reach_their_plugin(self):
        os.environ["AIS_UNRELATED"] = "keep"
        os.environ["CODEXBAR_PLUGIN_OTHER_TOKEN"] = "must-not-leak"
        original = sync.keychain_secret
        sync.keychain_secret = lambda service: "cookie-for-" + service
        try:
            config = dict(sync.DEFAULTS, pluginSecrets={
                "CODEXBAR_PLUGIN_HELMCODE_CREDITS_SESSION_COOKIE": "helm-item",
                "CODEXBAR_PLUGIN_OTHER_PLUGIN_TOKEN": "other-item"})
            env = sync.plugin_environment(config, "helmcode-credits")
        finally:
            sync.keychain_secret = original
            del os.environ["CODEXBAR_PLUGIN_OTHER_TOKEN"]
        self.assertEqual(env["CODEXBAR_PLUGIN_HELMCODE_CREDITS_SESSION_COOKIE"], "cookie-for-helm-item")
        self.assertNotIn("CODEXBAR_PLUGIN_OTHER_PLUGIN_TOKEN", env)
        self.assertNotIn("CODEXBAR_PLUGIN_OTHER_TOKEN", env)
        self.assertEqual(env["AIS_UNRELATED"], "keep")
