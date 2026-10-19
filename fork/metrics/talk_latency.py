#!/usr/bin/env python3
"""Summarize Talk Mode debug-overlay JSON. No acoustic/live verdict is inferred.

In a Debug app, open the talk latency popover and use Copy latency JSON. Save that
JSON, then run: python3 fork/metrics/talk_latency.py /path/to/turns.json
Omit the path to read stdin. Nil/missing measurements are excluded, not zeroed.
"""
import json
import math
import sys


STAGE_FIELDS = ("endOfTurnDecidedMs", "asrFinalMs", "sendIssuedMs", "firstStreamDeltaMs",
                "firstReasoningMs", "firstVisibleTokenMs", "firstSentenceReleasedMs", "firstAudioMs")
REQUIRED_FIELDS = tuple(f for f in STAGE_FIELDS if f != "firstReasoningMs") + ("reasoningDurationMs", "reasoningDeltaCount")
METRIC_FIELDS = STAGE_FIELDS + ("reasoningDurationMs", "reasoningDeltaCount", "firstTokenMs", "bargeInToStopMs")


def measured(row, field):
    value = row.get(field)
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and value >= 0
            and (field != "reasoningDeltaCount" or int(value) == value))


def ordering_errors(row):
    # ASR may complete before OR after the endpoint. Do not sort those stages.
    pairs = [("endOfTurnDecidedMs", "sendIssuedMs"), ("asrFinalMs", "sendIssuedMs"),
             ("sendIssuedMs", "firstStreamDeltaMs"), ("firstStreamDeltaMs", "firstVisibleTokenMs"),
             ("firstStreamDeltaMs", "firstReasoningMs"),
             ("firstVisibleTokenMs", "firstSentenceReleasedMs"), ("firstSentenceReleasedMs", "firstAudioMs")]
    return [f"{a} > {b}" for a, b in pairs if measured(row, a) and measured(row, b) and row[a] > row[b]]


def summarize(turns):
    rows = turns[-50:]
    result = {"evidence": "software timings only; acoustic latency unverified", "turns": len(rows)}
    for field in METRIC_FIELDS:
        values = sorted(row[field] for row in rows if measured(row, field))
        result[field] = {"samples": len(values), "missing": len(rows) - len(values),
                         "p50": values[math.ceil(len(values) * .5) - 1] if values else None,
                         "p90": values[math.ceil(len(values) * .9) - 1] if values else None}
    result["ordering_errors"] = [{"row": i, "errors": errors} for i, row in enumerate(rows)
                                  if (errors := ordering_errors(row))]
    eligible = [row for row in rows if measured(row, "asrFinalMs") and measured(row, "endOfTurnDecidedMs")]
    result["asr_before_endpoint"] = {"samples": len(eligible),
        "before": sum(row["asrFinalMs"] < row["endOfTurnDecidedMs"] for row in eligible),
        "missing": len(rows) - len(eligible)}
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
