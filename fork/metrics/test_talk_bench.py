"""Launcher tests with synthetic status only; no app or models are run."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import talk_bench as bench


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
                path.touch()
            path = models / "silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc"
            path.parent.mkdir(parents=True)
            path.touch()
            for name in ("cond_step.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder.mlmodelc", "mimi_decoder_v2.mlmodelc", "constants_bin"):
                path = home / ".cache/fluidaudio/Models/pocket-tts" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual(len(bench.require_models(home)), 3)

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
        result = self.scenario([{"firstTokenMs": 10, "firstAudioMs": 20}], {"error": None})
        self.assertEqual(result["status"], "COMPLETE")
        self.assertEqual(result["summary"]["firstAudioMs"]["p90"], 20)

    def test_missing_artifacts_and_samples_are_partial(self):
        for rows, status, code in [(None, None, 0), ([], {"error": None}, 0),
                                   ([{"firstTokenMs": 10}], {"error": None}, 0),
                                   ([{"firstTokenMs": 10, "firstAudioMs": 20}], {"error": None}, 1),
                                   ([{"firstTokenMs": 10, "firstAudioMs": 20}], {"error": "recognition failed"}, 0)]:
            self.assertEqual(self.scenario(rows, status, code)["status"], "PARTIAL")

    def test_barge_requires_attempt_and_observation(self):
        rows = [{"firstTokenMs": 10, "firstAudioMs": 20, "bargeInToStopMs": 1}]
        for attempted, observed in [(False, False), (True, False), (False, True), (True, True)]:
            result = self.scenario(rows, {"error": None, "bargeInAttempted": attempted, "bargeInObserved": observed}, barge=800)
            self.assertEqual(result["status"], "COMPLETE" if attempted and observed else "PARTIAL")


if __name__ == "__main__":
    unittest.main()
