"""Launcher tests with synthetic status only; no app or models are run."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import talk_bench as bench


def complete_row():
    return {"endOfTurnDecidedMs": 7, "asrFinalMs": 5, "sendIssuedMs": 8,
            "firstStreamDeltaMs": 9, "firstVisibleTokenMs": 10, "firstTokenMs": 10,
            "firstSentenceReleasedMs": 11, "firstAudioMs": 20,
            "reasoningDurationMs": 0, "reasoningDeltaCount": 0, "smartTurnChecks": 0, "endOfTurnReason": "silence"}


class TalkBenchTests(unittest.TestCase):
    def test_preflight_names_missing_models_without_downloading(self):
        with tempfile.TemporaryDirectory() as home:
            with self.assertRaises(ValueError) as caught:
                bench.require_models(Path(home))
            for name in ("Parakeet TDT v3", "Silero VAD", "PocketTTS", "does not download"):
                self.assertIn(name, str(caught.exception))

    def test_preflight_accepts_pinned_cache_layout(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            models = home / "Library/Application Support/FluidAudio/Models"
            for name in ("Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"):
                path = models / "parakeet-tdt-0.6b-v3" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                (path.touch() if name.endswith(".json") else path.mkdir())
            path = models / "silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc"
            path.parent.mkdir(parents=True)
            path.mkdir()
            for name in bench.POCKET_REQUIRED:
                path = home / ".cache/fluidaudio/Models/pocket-tts/v2.1/english" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.mkdir()
            self.assertEqual(len(bench.require_models(home)), 3)

    def test_pocket_shared_preferred_and_owned_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            shared = home / ".cache/fluidaudio/Models/pocket-tts/v2.1/english"
            owned = home / ".cache/osaurus/fluidaudio/Models/pocket-tts/v2.1/english"
            for name in bench.POCKET_REQUIRED:
                (owned / name).mkdir(parents=True)
            self.assertTrue(all(p.parent == owned for p in bench.pocket_model_paths(home)))
            for name in bench.POCKET_REQUIRED:
                (shared / name).mkdir(parents=True)
            self.assertTrue(all(p.parent == shared for p in bench.pocket_model_paths(home)))
            (shared / "cond_prefill.mlmodelc").rmdir()
            self.assertTrue(all(p.parent == owned for p in bench.pocket_model_paths(home)))

    def test_pocket_old_partial_and_files_are_not_ready(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            repo = home / ".cache/fluidaudio/Models/pocket-tts"
            for name in ("cond_step.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder.mlmodelc", "mimi_decoder_v2.mlmodelc", "constants_bin"):
                (repo / name).mkdir(parents=True)
            # Even all the new names as plain files cannot pass the directory probe.
            for name in bench.POCKET_REQUIRED:
                path = repo / "v2.1/english" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            with self.assertRaises(ValueError) as caught:
                bench.require_models(home)
            self.assertIn("v2.1/english/cond_prefill.mlmodelc", str(caught.exception))
            self.assertTrue((repo / "cond_step.mlmodelc").is_dir())

    def test_isolated_configuration_preserves_model_defaults(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            model = base / "model"
            model.mkdir()
            bench.prepare_root(base / "root", "owner/model", model)
            self.assertEqual((base / "root/models/owner/model").resolve(), model.resolve())
            self.assertEqual(json.loads((base / "root/config/default-agent.json").read_text()), {"defaultModel": "owner/model"})
            self.assertEqual(json.loads((base / "root/config/voice/speech.json").read_text())["voiceInputEnabled"], False)

    def scenario(self, rows, status=None, exit_code=0, barge=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "scenario"
            def launch(args, *, env, stdout, stderr):
                self.assertEqual(env["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"], "1")
                self.assertEqual(env["OSAURUS_TALK_AUTOSTART"], "default")
                if rows is not None:
                    bench.write_json(root / "turns.json", rows)
                if status is not None:
                    bench.write_json(root / "turns.json.status.json", status)
                class Process:
                    returncode = exit_code
                    def wait(self, timeout): return exit_code
                return Process()
            with patch.object(bench.subprocess, "Popen", launch):
                return bench.run_scenario(Path("/fake/osaurus"), root, [Path("/input.wav")], "test/model", Path(temporary), barge)

    def test_complete_latency_samples(self):
        result = self.scenario([complete_row()], {"error": None})
        self.assertEqual(result["status"], "COMPLETE")
        self.assertEqual(result["summary"]["firstAudioMs"]["p90"], 20)

    def test_missing_artifacts_and_samples_are_partial(self):
        for rows, status, code in [(None, None, 0), ([], {"error": None}, 0),
                                   ([{"firstTokenMs": 10}], {"error": None}, 0),
                                   ([{"firstTokenMs": 10, "firstAudioMs": 20}], {"error": None}, 1),
                                   ([{"firstTokenMs": 10, "firstAudioMs": 20}], {"error": "recognition failed"}, 0)]:
            self.assertEqual(self.scenario(rows, status, code)["status"], "PARTIAL")

    def test_barge_requires_attempt_and_observation(self):
        rows = [dict(complete_row(), bargeInToStopMs=1)]
        for attempted, observed in [(False, False), (True, False), (False, True), (True, True)]:
            result = self.scenario(rows, {"error": None, "bargeInAttempted": attempted, "bargeInObserved": observed}, barge=800)
            self.assertEqual(result["status"], "COMPLETE" if attempted and observed else "PARTIAL")

    def test_each_stage_required_and_reasoning_conditional(self):
        for field in bench.REQUIRED_FIELDS:
            row = complete_row()
            del row[field]
            self.assertEqual(self.scenario([row], {"error": None})["status"], "PARTIAL", field)
        row = dict(complete_row(), reasoningDeltaCount=3, reasoningDurationMs=1)
        self.assertEqual(self.scenario([row], {"error": None})["status"], "PARTIAL")
        row["firstReasoningMs"] = 9
        self.assertEqual(self.scenario([row], {"error": None})["status"], "COMPLETE")
        row["firstSentenceReleasedMs"] = 21
        self.assertEqual(self.scenario([row], {"error": None})["status"], "PARTIAL")

    def test_stage_percentiles_missing_invalid_and_retention(self):
        from talk_latency import summarize, METRIC_FIELDS
        rows = [{field: (n / 100 if field == "smartTurnProbability" else n) for field in METRIC_FIELDS} for n in range(1, 61)]
        summary = summarize(rows)
        for field in METRIC_FIELDS:
            self.assertEqual(summary[field], {"samples": 50, "missing": 0, "p50": 0.35 if field == "smartTurnProbability" else 35, "p90": 0.55 if field == "smartTurnProbability" else 55})
        invalid = summarize([{field: value for field in METRIC_FIELDS}
                             for value in [None, True, -1, float("nan"), float("inf")]])
        for field in METRIC_FIELDS:
            self.assertEqual(invalid[field], {"samples": 0, "missing": 5, "p50": None, "p90": None})
        self.assertEqual(summarize([])["firstReasoningMs"]["samples"], 0)

    def test_smart_turn_completion_requires_endpoint_telemetry(self):
        row = dict(complete_row(), endOfTurnReason="smartTurn", smartTurnChecks=1, smartTurnProbability=0.9)
        self.assertEqual(self.scenario([row], {"error": None})["status"], "COMPLETE")
        for field in ("endOfTurnReason", "smartTurnChecks", "smartTurnProbability"):
            missing = dict(row)
            del missing[field]
            self.assertEqual(self.scenario([missing], {"error": None})["status"], "PARTIAL")
        self.assertEqual(self.scenario([dict(row, smartTurnChecks=0)], {"error": None})["status"], "PARTIAL")

    def test_smart_turn_summary_keeps_failures_missing_and_silence_rows(self):
        from talk_latency import summarize
        rows = [{"smartTurnChecks": 1, "smartTurnProbability": 0.8, "endOfTurnReason": "smartTurn"},
                {"smartTurnChecks": 4, "smartTurnProbability": 0.4, "endOfTurnReason": "silence"},
                {"smartTurnChecks": 0, "endOfTurnReason": "silence"}, {},
                {"smartTurnChecks": 1.5, "smartTurnProbability": 1.1, "endOfTurnReason": "invalid"}]
        stats = summarize(rows)
        self.assertEqual(stats["smartTurnChecks"], {"samples": 3, "missing": 2, "p50": 1, "p90": 4})
        self.assertEqual(stats["smartTurnProbability"], {"samples": 2, "missing": 3, "p50": 0.4, "p90": 0.8})
        self.assertEqual(stats["endOfTurnReason"], {"smartTurn": 1, "silence": 2, "missing": 2})

    def test_asr_order_is_not_assumed_and_legacy_data_stays_missing(self):
        from talk_latency import summarize
        early = complete_row()
        late = dict(early, asrFinalMs=7.5)
        stats = summarize([early, late, {"firstTokenMs": 10}])
        self.assertEqual(stats["ordering_errors"], [])
        self.assertEqual(stats["asr_before_endpoint"], {"samples": 2, "before": 1, "missing": 1})
        self.assertEqual(stats["sendIssuedMs"]["missing"], 1)
        self.assertEqual(stats["firstReasoningMs"]["samples"], 0)


if __name__ == "__main__":
    unittest.main()
