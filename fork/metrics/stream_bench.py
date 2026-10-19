"""Stream a fixed chat completion from a running osaurus server and time it.

usage: python3 -I stream_bench.py PORT MODEL_ID
Prints JSON: cold and warm time-to-first-token, decode tokens/s.
"""
import json
import sys
import time
import urllib.request

PORT, MODEL = sys.argv[1], sys.argv[2]
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"
PROMPT = (
    "Write a short, friendly paragraph (about 120 words) explaining why the "
    "sky looks blue during the day and red at sunset."
)


def run_once():
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "stream": True,
        "max_tokens": 200,
        "temperature": 0,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json"})
    start = time.time()
    first = None
    chunks = 0
    usage = None
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            obj = json.loads(data)
            if obj.get("usage"):
                usage = obj["usage"]
            for choice in obj.get("choices", []):
                delta = choice.get("delta", {})
                if delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning"):
                    if first is None:
                        first = time.time()
                    chunks += 1
    end = time.time()
    tokens = (usage or {}).get("completion_tokens") or chunks
    decode_s = max(end - (first or end), 1e-6)
    return {
        "ttft_s": round((first or end) - start, 3),
        "completion_tokens": tokens,
        "decode_tok_s": round(max(tokens - 1, 0) / decode_s, 1),
        "total_s": round(end - start, 2),
    }


cold = run_once()
warm = [run_once() for _ in range(3)]
warm.sort(key=lambda r: r["ttft_s"])
mid = warm[1]
print(json.dumps({
    "cold_ttft_s": cold["ttft_s"],
    "warm_ttft_s_median": mid["ttft_s"],
    "decode_tok_s_median": sorted(r["decode_tok_s"] for r in warm)[1],
    "completion_tokens": mid["completion_tokens"],
    "runs": {"cold": cold, "warm": warm},
}))
