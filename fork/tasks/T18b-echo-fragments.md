# T18b — Echo defense: fragments that slip through, and a missed real barge-in

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, `fork/tasks/T18-echo-robustness.RESULT.md`.
Code: `Packages/OsaurusCore/Services/Voice/TalkEchoPolicy.swift`,
`TalkModeReducer.swift`, `TalkModeController.swift`, `Tests/Voice/TalkEchoTests.swift`,
harness `fork/metrics/talk_bench.py`.

## Evidence (fork/metrics/results/talk-t18-qwen35-4b.json, Qwen3.5-4B, echo −20 dB / 30 ms)

| scenario | status | first audio p50 | echo rejected | echo **sent** | self barge-ins | real barge-in |
|---|---|---|---|---|---|---|
| baseline | COMPLETE | 1179 ms | – | – | – | – |
| barge_in | COMPLETE | 1101 ms | – | – | – | observed |
| echo | PARTIAL | 1159 ms | 8 | **2** | **2** | – |
| echo_barge_in | PARTIAL | 7180 ms | 1 | 0 | 0 | **NOT observed** |

Chat history of the echo run (what was sent as user turns):

```
user: What's the capital of France?      assistant: The capital of France is Paris.
user: is parent.                          ← echo of "…is Paris." (ASR mishearing)
user: What is 7 plus 8?                   assistant: 7 plus 8 equals 15.
user: Seven                               ← echo of spoken "seven plus eight…"; agent text has digit "7"
```

Root causes in the self-transcript check:
1. Token overlap 1/2 = 0.5 < 0.6 for "is parent" vs "...is Paris" — no fuzzy token
   matching for ASR mishearings.
2. Digits in agent text vs number words in ASR output ("7" vs "seven") — no
   number normalization.
3. Very short fragments (1–2 tokens, < ~600 ms speech) that **start during
   agent playback** get no extra scrutiny.

## Deliverables

1. **Normalization** for both sides: lowercase, strip punctuation, expand
   integers 0–9999 and simple decimals to words ("7" → "seven", "15" →
   "fifteen", "3.5" → "three point five"), common symbols ("%" → "percent",
   "&" → "and"), contractions consistently.
2. **Fuzzy token match**: a user token matches an agent token if equal or
   normalized-Levenshtein similarity ≥ 0.6 for tokens ≥ 4 chars (e.g.
   parent/paris), or same first 3 letters + similar length for shorter ones —
   keep it conservative and tested. Overlap ratio uses fuzzy matches, plus a
   contiguous-sequence rule: ≥ 2 consecutive matching tokens in order counts as
   echo even if the overall ratio is lower.
3. **Short-fragment rule**: a segment with ≤ 2 tokens (after normalization) or
   < 600 ms of speech **whose speech began while the agent was playing or within
   400 ms after playback** is echo if any token fuzzy-matches the agent's last
   10 s of spoken text; otherwise it is ignored (not sent) unless its mic RMS was
   ≥ echo floor × 4. Users who genuinely say one word during playback will need
   to repeat — acceptable; document it.
4. **Missed real barge-in** (echo_barge_in): find out from the evidence logs
   why the real user interruption ("What's the capital of France?" injected at
   800 ms into the reply, with echo mixed in) was not observed — echo-floor
   gate too high? threshold? transcript check rejecting it (shares "the"/"of")?
   Fix the root cause: e.g. echo floor must track only frames where VAD is low
   and the mic is dominated by the playback signal; transcript rejection must
   ignore stop-words when computing overlap. Real barge-in must still work with
   echo present.
5. Tests: the exact two leaked phrases above must be rejected; real questions
   that share stop-words with the agent's text must pass; digit/word cases;
   fuzzy edge cases (no false match for unrelated words of similar length).
6. Update the harness pass criteria: echo scenario requires `echoSegmentsSent
   == 0` and `selfBargeIns == 0`; echo_barge_in requires the real barge-in to be
   observed.

Commit on your branch; write `fork/tasks/T18b-echo-fragments.RESULT.md`.
Claude will rebuild and rerun the four-scenario benchmark.
