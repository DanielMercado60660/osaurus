#!/usr/bin/env python3
"""Isolated T03 regression + T06 tests; real source, inert app/provider stubs.
No microphone, speakers, model, keychain or network. Not app integration proof.
"""
import os
from pathlib import Path
import runpy
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
# Reuse the documented T03 stubs, then copy the resulting package to this lane.
runpy.run_path(str(root / "fork/tasks/T03-talk-mode.verify.py"))
dest = root / "build/t06-harness"
shutil.copytree(root / "build/t03-harness", dest, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns(".build"))
src = dest / "Sources/OsaurusCore"
core = root / "Packages/OsaurusCore"
shutil.copy(core / "Tests/Voice/TalkBenchmarkTests.swift", dest / "Tests/OsaurusCoreTests")
env = os.environ.copy()
env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
           CLANG_MODULE_CACHE_PATH=str(root / "build/ModuleCache"), SWIFTPM_MODULECACHE_OVERRIDE=str(root / "build/ModuleCache"),
           OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS="1", OSAURUS_TEST_ROOT=str(root / "build/t06-test"), OSU_MODELS_DIR=str(root / "build/t06-test-models"))
# Tests must not accidentally enable the process-wide file-input seam.
for key in list(env):
    if key.startswith("OSAURUS_TALK_"): del env[key]
command = ["swift", "test", "--disable-keychain", "--disable-sandbox", "--build-system", "native",
           "--package-path", str(dest), "--cache-path", str(root / "build/swiftpm-cache"),
           "--config-path", str(root / "build/swiftpm-config"), "--security-path", str(root / "build/swiftpm-security"), "--jobs", "4"]
log = root / "build/t06-proof/isolated.log"
log.parent.mkdir(parents=True, exist_ok=True)
print("Running:", " ".join(command), flush=True)
with log.open("w") as output:
    result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
print("Exit:", result.returncode, "Log:", log)
raise SystemExit(result.returncode)
