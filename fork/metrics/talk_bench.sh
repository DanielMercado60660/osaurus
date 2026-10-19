#!/usr/bin/env bash
# Usage: LABEL=my-build fork/metrics/talk_bench.sh APP MODEL_ID MODEL_DIR
# Requires cached Parakeet v3, Silero VAD and PocketTTS. Never downloads models.
set -euo pipefail
if [[ $# -ne 3 ]]; then
  echo 'Usage: [LABEL=name] talk_bench.sh /path/osaurus.app MODEL_ID MODEL_DIR' >&2
  exit 2
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I "$HERE/talk_bench.py" "$@"
