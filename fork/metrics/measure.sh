#!/usr/bin/env bash
# Measure an osaurus app build: bundle size, launch-to-ready, idle memory,
# time to first token, decode speed, and memory with a model loaded.
#
# usage: fork/metrics/measure.sh /path/to/osaurus.app LABEL MODEL_ID MODEL_DIR
#   MODEL_ID  e.g. mlx-community/Qwen3.5-4B-4bit  (folder name under the models dir)
#   MODEL_DIR folder holding config.json + safetensors for that model
# Writes fork/metrics/results/<LABEL>.json and prints it.
set -euo pipefail

APP="$1"; LABEL="$2"; MODEL_ID="$3"; MODEL_DIR="$4"
PORT="${PORT:-1337}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="/tmp/osaurus-metrics-$LABEL"
BIN="$APP/Contents/MacOS/osaurus"

rm -rf "$ROOT"; mkdir -p "$ROOT/models/$(dirname "$MODEL_ID")" "$HERE/results"
ln -s "$MODEL_DIR" "$ROOT/models/$MODEL_ID"

footprint_mb() { # physical footprint of a pid in MB
  /usr/bin/footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ {v=$2; u=$3} END {
    if (u ~ /GB/) v*=1024; else if (u ~ /KB/) v/=1024; printf "%.0f", v }'
}

BUNDLE_MB=$(du -sm "$APP" | cut -f1)

if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT already in use; quit other osaurus instances first" >&2; exit 1
fi

T0=$(python3 -c 'import time; print(time.time())')
env OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT="$ROOT" \
    OSU_MODELS_DIR="$ROOT/models" "$BIN" >"$ROOT/app.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

READY=""
for _ in $(seq 1 600); do
  if curl -fsS "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
    READY=$(python3 -c "import time; print(round(time.time()-$T0, 2))"); break
  fi
  sleep 0.1
done
[[ -n "$READY" ]] || { echo "server never came up; see $ROOT/app.log" >&2; exit 1; }

sleep 30
IDLE_MB=$(footprint_mb "$PID")

python3 -I "$HERE/stream_bench.py" "$PORT" "$MODEL_ID" > "$ROOT/bench.json"
LOADED_MB=$(footprint_mb "$PID")

python3 -I - "$LABEL" "$APP" "$BUNDLE_MB" "$READY" "$IDLE_MB" "$LOADED_MB" "$MODEL_ID" "$ROOT/bench.json" <<'PY' | tee "$HERE/results/$LABEL.json"
import json, sys, subprocess, datetime
label, app, bundle, ready, idle, loaded, model, bench = sys.argv[1:]
b = json.load(open(bench))
print(json.dumps({
    "label": label,
    "date": datetime.datetime.now().isoformat(timespec="seconds"),
    "app": app,
    "bundle_mb": int(bundle),
    "launch_to_server_ready_s": float(ready),
    "idle_footprint_mb": int(idle or 0),
    "model": model,
    "model_loaded_footprint_mb": int(loaded or 0),
    **b,
}, indent=2))
PY
