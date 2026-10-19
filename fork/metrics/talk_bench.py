#!/usr/bin/env python3
"""Deterministic launcher/reporting for talk_bench.sh, not an agent worker."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from talk_latency import summarize, REQUIRED_FIELDS, measured

HERE = Path(__file__).resolve().parent


def require_models(home):
    """Paths/names match the pinned FluidAudio loaders, including VAD and vocab."""
    models = home / "Library/Application Support/FluidAudio/Models"
    required = {
        "Parakeet TDT v3 (FluidInference/parakeet-tdt-0.6b-v3-coreml), Voice → Voice Setup":
            [models / "parakeet-tdt-0.6b-v3" / name for name in
             ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]],
        "Silero VAD (FluidInference/silero-vad-coreml), loaded with Voice Setup":
            [models / "silero-vad/silero-vad-unified-256ms-v6.0.0.mlmodelc"],
        "PocketTTS (FluidInference/pocket-tts-coreml), Voice → Text To Speech":
            [home / ".cache/fluidaudio/Models/pocket-tts" / name for name in
             ["cond_step.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder.mlmodelc", "mimi_decoder_v2.mlmodelc", "constants_bin"]],
    }
    missing = [(name, path) for name, paths in required.items() for path in paths if not path.exists()]
    if missing:
        details = "\n".join(f"  {name}\n    missing: {path}" for name, path in missing)
        raise ValueError("Download these speech resources in Osaurus before benchmarking; this script does not download:\n" + details)
    return {name: [str(p) for p in paths] for name, paths in required.items()}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def prepare_root(root, model_id, model_dir):
    voice = root / "config/voice"
    voice.mkdir(parents=True)
    link = root / "models" / model_id
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(model_dir, target_is_directory=True)
    write_json(root / "config/default-agent.json", {"defaultModel": model_id})
    write_json(voice / "speech.json", {"modelVersion": "v3", "voiceInputEnabled": False})
    write_json(voice / "tts.json", {"provider": "pocketTTS", "voice": "alba", "temperature": 0.7})
    write_json(voice / "vad.json", {"vadModeEnabled": False})
    write_json(voice / "talk.json", {"enabledAgentIds": ["00000000-0000-0000-0000-000000000001"],
                                   "bargeInEnabled": True, "endOfTurnSilenceMs": 700, "thinkBeforeSpeaking": False})
    # Avoid colliding with an ordinary running Osaurus server. No server calls
    # are used for chat: the real ChatSession owns the in-process turn.
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    write_json(root / "config/server.json", {"port": port})


def run_scenario(binary, root, wavs, model_id, model_dir, barge_ms=None):
    prepare_root(root, model_id, model_dir)
    metrics = root / "turns.json"
    env = {key: value for key, value in os.environ.items() if not key.startswith("OSAURUS_TALK_")}
    env.update(OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS="1", OSAURUS_TEST_ROOT=str(root),
               OSU_MODELS_DIR=str(root / "models"), OSAURUS_TALK_INPUT_WAV=",".join(map(str, wavs)),
               OSAURUS_TALK_AUTOSTART="default", OSAURUS_TALK_METRICS_OUT=str(metrics),
               OSAURUS_TALK_LEADING_SILENCE_MS="500", OSAURUS_TALK_TRAILING_SILENCE_MS="1200",
               OSAURUS_TALK_TIMEOUT_MS="180000", GIT_TERMINAL_PROMPT="0",
               GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="")
    if barge_ms is not None:
        env["OSAURUS_TALK_BARGE_IN_AFTER_MS"] = str(barge_ms)
    error = None
    with (root / "app.log").open("w") as log:
        process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=240 * (len(wavs) + 1))
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if isinstance(exc, KeyboardInterrupt):
                raise
            error = "App watchdog expired; see app.log"
    turns = json.loads(metrics.read_text()) if metrics.exists() else []
    sidecar = Path(str(metrics) + ".status.json")
    status = json.loads(sidecar.read_text()) if sidecar.exists() else {"error": "App did not write completion status"}
    stats = summarize(turns)
    complete = (error is None and process.returncode == 0 and status.get("error") is None
                and len(turns) == len(wavs)
                and all(stats[field]["missing"] == 0 for field in REQUIRED_FIELDS)
                and not stats["ordering_errors"]
                and all(row.get("reasoningDeltaCount") == 0 or measured(row, "firstReasoningMs") for row in turns))
    if barge_ms is not None:
        complete = complete and status.get("bargeInAttempted") is True and status.get("bargeInObserved") is True
    return {"status": "COMPLETE" if complete else "PARTIAL", "exit_code": process.returncode,
            "watchdog_error": error, "completion": status, "summary": stats, "turns": turns,
            "evidence_root": str(root), "barge_in_after_ms": barge_ms}


def main():
    if len(sys.argv) != 4:
        raise ValueError("Usage: talk_bench.sh APP MODEL_ID MODEL_DIR")
    app, model_id, model_dir_arg = sys.argv[1:]
    binary = Path(app).resolve() / "Contents/MacOS/osaurus"
    model_dir = Path(model_dir_arg).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"App executable not found: {binary}")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", model_id) or any(p in (".", "..") for p in model_id.split("/")):
        raise ValueError("MODEL_ID must be a relative model identifier without traversal")
    if not (model_dir / "config.json").is_file() or not list(model_dir.glob("*.safetensors")):
        raise ValueError(f"MODEL_DIR needs config.json and safetensors: {model_dir}")
    label = os.environ.get("LABEL", datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    if not re.fullmatch(r"[A-Za-z0-9_-]+", label):
        raise ValueError("LABEL may contain only letters, digits, underscores and hyphens")
    resources = require_models(Path.home())
    root = Path(tempfile.mkdtemp(prefix=f"osaurus-talk-{label}-"))
    print(f"Evidence retained at {root}", file=sys.stderr)
    questions = ["Why is the sky blue? Explain it in five sentences.", "What's the capital of France?",
                 "What is seven plus eight?", "Which is the largest ocean on Earth?"]
    wavs = []
    for index, question in enumerate(questions):
        aiff, wav = root / f"input-{index}.aiff", root / f"input-{index}.wav"
        subprocess.run(["/usr/bin/say", "-o", str(aiff), question], check=True)
        subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
        wavs.append(wav)
    baseline = run_scenario(binary, root / "baseline", wavs, model_id, model_dir)
    barge = run_scenario(binary, root / "barge-in", wavs[:2], model_id, model_dir, barge_ms=800)
    pins = json.loads((HERE.parents[1] / "Packages/OsaurusCore/Package.resolved").read_text())["pins"]
    generation = model_dir / "generation_config.json"
    result = {"label": label, "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "status": "COMPLETE" if baseline["status"] == barge["status"] == "COMPLETE" else "PARTIAL",
              "evidence": "Software latency through real models and paced null audio. Not acoustic or release proof.",
              "checkout_sha": subprocess.check_output(["git", "-C", str(HERE), "rev-parse", "HEAD"], text=True).strip(),
              "app_source_sha": os.environ.get("APP_SOURCE_SHA", "unverified: set APP_SOURCE_SHA to the app's actual build SHA"),
              "app": str(binary.parent.parent.parent), "app_executable_sha256": digest(binary),
              "checkout_vmlx_pin": [p for p in pins if "vmlx" in p["identity"].lower()],
              "model": model_id, "model_dir": str(model_dir), "model_config_sha256": digest(model_dir / "config.json"),
              "generation_config": json.loads(generation.read_text()) if generation.exists() else None,
              "generation_overrides": {"talkThinkBeforeSpeaking": False,
                  "enable_thinking": "false only when the bundle declares a thinking toggle; otherwise omitted"}, "speech_resources": resources,
              "tts": {"provider": "pocketTTS", "voice": "alba", "temperature": 0.7},
              "inputs": [{"question": q, "wav": str(w), "sha256": digest(w)} for q, w in zip(questions, wavs)],
              "baseline": baseline, "barge_in": barge}
    (HERE / "results").mkdir(exist_ok=True)
    write_json(HERE / "results" / f"talk-{label}.json", result)
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "COMPLETE" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc))
