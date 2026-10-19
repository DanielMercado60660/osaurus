#!/usr/bin/env python3
"""Summarize Talk Mode debug-overlay JSON. No acoustic/live verdict is inferred.

In a Debug app, open the talk latency popover and use Copy latency JSON. Save that
JSON, then run: python3 fork/metrics/talk_latency.py /path/to/turns.json
Omit the path to read stdin. Nil/missing measurements are excluded, not zeroed.
"""
import json
import math
import sys


def summarize(turns):
    rows = turns[-50:]
    result = {"evidence": "software timings only; acoustic latency unverified", "turns": len(rows)}
    for field in ("firstTokenMs", "firstAudioMs", "bargeInToStopMs"):
        values = sorted(row[field] for row in rows
                        if isinstance(row.get(field), (int, float))
                        and not isinstance(row[field], bool)
                        and math.isfinite(row[field]) and row[field] >= 0)
        result[field] = {"samples": len(values), "missing": len(rows) - len(values),
                         "p50": values[math.ceil(len(values) * .5) - 1] if values else None,
                         "p90": values[math.ceil(len(values) * .9) - 1] if values else None}
    return result


if __name__ == "__main__":
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as source:
            turns = json.load(source)
    else:
        turns = json.load(sys.stdin)
    if not isinstance(turns, list) or not all(isinstance(row, dict) for row in turns):
        raise SystemExit("Expected the array from Talk Mode's Copy latency JSON control.")
    print(json.dumps(summarize(turns), indent=2))
