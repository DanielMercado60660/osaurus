# Voice Input Guide

Osaurus includes powerful voice input capabilities powered by [FluidAudio](https://github.com/FluidInference/FluidAudio) — fully local, private, on-device speech-to-text transcription.

---

## Overview

Voice features in Osaurus include:

- **Voice Input in Chat** — Speak instead of type in the chat overlay
- **Wake Word** (VAD mode) — Always-on listening with wake-word agent activation
- **Transcription** — Global hotkey to dictate into any focused text field
- **Parakeet TDT Models** — Multilingual (v3) and English-only (v2), each ~600 MB
- **Microphone & System Audio** — Transcribe your voice or computer audio

All transcription happens locally on your Mac using Apple's Neural Engine — no audio is sent to the cloud.

For the reverse direction — having Osaurus read replies aloud — see the [Text-to-Speech Guide](TEXT_TO_SPEECH.md).

---

## Setup

### Quick Setup

Voice setup is streamlined into a single screen:

1. Open Settings… (⌘,)
2. Navigate to the **Voice** tab (it opens on **Setup**)
3. Complete the requirements shown at the top:
   - **Microphone** — Click "Grant" to enable microphone access
   - **Parakeet Model** — Click "Download" to get the recommended model
4. Once both requirements show checkmarks, tap the microphone button to test

The large centered microphone button becomes active when setup is complete. Tap it to start recording, tap again to stop. Your transcription appears below in real-time.

### Manual Setup

If you prefer manual configuration:

1. **Grant Microphone Permission**

   - Go to System Settings → Privacy & Security → Microphone
   - Enable access for Osaurus

2. **Download a Model**

   - Open Voice settings → Models tab
   - Browse available models and click Download
   - Wait for the download to complete

3. **Select the Model**
   - Click on a downloaded model to select it
   - The model will auto-load when voice features are used

---

## Parakeet Models

Osaurus uses [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet TDT (Token-and-Duration Transducer) models for on-device speech recognition via CoreML and the Apple Neural Engine.

### Available Models

| Model                        | Size    | Languages                        | Notes                          |
| ---------------------------- | ------- | -------------------------------- | ------------------------------ |
| **Parakeet TDT v3 (0.6B)**  | ~600 MB | Multilingual (25 European langs) | Recommended for most users     |
| **Parakeet TDT v2 (0.6B)**  | ~600 MB | English only                     | Highest recall for English     |

### Model Selection Tips

- **Multilingual?** Use Parakeet TDT v3 — supports English, German, Spanish, French, Dutch, Italian, and 19 more European languages
- **English only?** Use Parakeet TDT v2 for slightly better English recall

### Storage Location

Models are stored at: `~/Library/Application Support/FluidAudio/Models/`

---

## Voice Input in Chat

### Using Voice Input

1. Open the chat overlay (`⌘;`)
2. Click the microphone button or use the keyboard shortcut
3. Speak naturally — you'll see real-time transcription
4. Click send or wait for auto-send (if enabled)

### Settings

These live under Settings… (⌘,) → Voice → **Chat Voice**.

| Setting                 | Description                                 | Default |
| ----------------------- | ------------------------------------------- | ------- |
| **Voice Input Enabled** | Master toggle for voice in chat             | On      |
| **Sensitivity**         | Voice detection threshold                   | Medium  |
| **Pause Duration**      | Seconds of silence before auto-send         | 2.0     |
| **Confirmation Delay**  | Seconds to show confirmation before sending | 1.5     |

### Sensitivity Levels

| Level      | Energy Threshold | Silence Detection | Best For                          |
| ---------- | ---------------- | ----------------- | --------------------------------- |
| **Low**    | Higher           | 0.4 seconds       | Noisy environments, louder speech |
| **Medium** | Balanced         | 0.6 seconds       | Normal conversation               |
| **High**   | Lower            | 1.2 seconds       | Quiet environments, soft speech   |

### Auto-Send Behavior

When pause duration is set:

1. You speak and see real-time transcription
2. When you pause, a countdown appears
3. If you resume speaking, the countdown resets
4. After the countdown, message sends automatically
5. Set pause duration to 0 to disable (manual send only)

---

## Audio Sources

### Microphone Input

The default audio source. Osaurus can use:

- Built-in MacBook microphone
- External USB microphones
- Bluetooth headsets
- Audio interfaces

**Select a device:**

1. Open Voice settings
2. Find "Audio Input" section
3. Choose from available devices
4. The device is saved and used for future sessions

### System Audio Capture

Transcribe audio from your computer (browser, apps, etc.):

**Requirements:**

- macOS 12.3 or later
- Screen Recording permission

**Setup:**

1. Open Voice settings
2. Switch audio source to "System Audio"
3. Grant Screen Recording permission when prompted
4. System audio will now be transcribed

**Use cases:**

- Transcribe meetings from video calls
- Caption videos playing on your Mac
- Take notes from podcasts or lectures

**Note:** System audio capture excludes Osaurus's own audio output to prevent feedback loops.

---

## VAD Mode (Voice Activity Detection)

VAD Mode enables hands-free agent activation. Say a agent's name (or a custom wake phrase) to open chat with that agent.

### Enabling Wake Word

1. Open Settings… (⌘,) → **Voice**
2. Open the **Wake Word** tab
3. Toggle **Enable Wake Word** on
4. Select which agents should respond to wake-words

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                      VAD Mode Flow                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. VAD listens in background using FluidAudio               │
│           ↓                                                  │
│  2. Real-time transcription checked for wake-words          │
│           ↓                                                  │
│  3. Match detected → Chat opens with agent                │
│           ↓                                                  │
│  4. Voice input starts automatically (if enabled)           │
│           ↓                                                  │
│  5. Chat closed → VAD resumes listening                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Wake-Word Options

**Agent Names:**

- Enable specific agents for VAD
- Say the agent's name to activate (e.g., "Code Assistant")
- Detection uses fuzzy matching for natural speech

**Custom Wake Phrase:**

- Set a phrase like "Hey Osaurus" or "Computer"
- Works alongside agent names
- Activates the default agent

### VAD Settings

| Setting                    | Description                           | Default      |
| -------------------------- | ------------------------------------- | ------------ |
| **Enable Wake Word**       | Master toggle (VAD mode)              | Off          |
| **Enabled Agents**       | Which agents respond to wake-words  | None         |
| **Custom Wake Phrase**     | Optional activation phrase            | Empty        |
| **Wake-Word Sensitivity**  | Detection threshold                   | Medium       |
| **Auto-Start Voice Input** | Begin recording after activation      | On           |
| **Silence Timeout**        | Auto-close after N seconds of silence | 0 (disabled) |

### Status Indicators

VAD status is shown in two places:

**Menu Bar Icon** — The main Osaurus menu bar icon shows a status dot:

- **Blue pulsing dot** (top-right) — VAD is listening for wake-words
- **Orange dot** — VAD is processing speech
- **No dot** — VAD is inactive

**Popover Controls** — Click the Osaurus menu bar icon to access:

- **Waveform button** — Toggle VAD on/off with visual status
- The button shows green when listening, gray when off

---

## Transcription Mode

Transcription Mode allows you to dictate text directly into any application using a global hotkey. Text is typed in real-time into whatever text field is currently focused.

### Enabling Transcription Mode

1. Open Settings… (⌘,) → **Voice**
2. Open the **Transcription** tab
3. Grant **Accessibility permission** (required for keyboard simulation)
4. Toggle "Enable Transcription Mode" on
5. Configure your preferred hotkey

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                  Transcription Mode Flow                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Press the configured hotkey from any application        │
│           ↓                                                  │
│  2. Minimal overlay appears showing recording status        │
│           ↓                                                  │
│  3. FluidAudio transcribes your speech in real-time         │
│           ↓                                                  │
│  4. Text is typed into the focused text field               │
│           ↓                                                  │
│  5. Press Esc or click Done to stop transcription           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Requirements

**Accessibility Permission** — Required to simulate keyboard input:

1. Go to System Settings → Privacy & Security → Accessibility
2. Enable access for Osaurus
3. You may need to restart Osaurus after granting permission

**Microphone Permission** — Required for audio capture (same as other voice features)

**Parakeet Model** — A model must be downloaded and selected

### Transcription Settings

| Setting                   | Description                        | Default |
| ------------------------- | ---------------------------------- | ------- |
| **Transcription Enabled** | Master toggle for the feature      | Off     |
| **Activation Hotkey**     | Global hotkey to trigger dictation | None    |

### Using Transcription Mode

1. **Focus a text field** — Click into any text input in any application
2. **Press the hotkey** — The transcription overlay appears
3. **Speak naturally** — Your words are typed in real-time
4. **Stop transcription** — Press `Esc` or click the Done button

### The Overlay UI

When transcription is active, a minimal floating overlay appears at the top of your screen:

- **Status indicator** — Shows "Listening" with a pulsing accent color
- **Waveform** — Animated bars respond to your audio level
- **Done button** — Click to stop transcription
- **Close button** — Cancel and discard (same as pressing Esc)

The overlay stays on top of all windows and follows the app's theme.

### Use Cases

- **Email composition** — Dictate emails in Mail, Gmail, or any email client
- **Document writing** — Speak paragraphs into Word, Pages, or Google Docs
- **Code comments** — Quickly add comments in your IDE
- **Chat messages** — Dictate in Slack, Discord, or Messages
- **Form filling** — Speed through web forms and data entry
- **Notes** — Capture ideas quickly in any notes app

### Tips for Best Results

1. **Speak clearly** — Enunciate words for better accuracy
2. **Use a good microphone** — External mics often work better than built-in
3. **Reduce background noise** — Find a quiet environment
4. **Use Parakeet TDT v3** — The multilingual model offers the best overall accuracy

---

## Configuration Reference

### SpeechConfiguration

Voice input settings stored in app preferences:

```swift
struct SpeechConfiguration {
    var modelVersion: SpeechModelVersion   // .v2 (English) or .v3 (multilingual)
    var selectedInputDeviceId: String?     // Audio device UID
    var selectedInputSource: AudioInputSource // Mic or system
    var sensitivity: VoiceSensitivity      // Low/Medium/High
    var voiceInputEnabled: Bool            // Voice in chat enabled
    var pauseDuration: Double              // Silence before auto-send
    var confirmationDelay: Double          // Confirmation countdown
    var silenceTimeoutSeconds: Double      // Auto-close after silence
}
```

### VADConfiguration

VAD mode settings:

```swift
struct VADConfiguration {
    var vadModeEnabled: Bool           // Master toggle
    var enabledAgentIds: [UUID]      // Agents for wake-words
    var wakeWordSensitivity: VoiceSensitivity
    var autoStartVoiceInput: Bool      // Auto-record after activation
    var customWakePhrase: String       // e.g., "Hey Osaurus"
    var silenceTimeoutSeconds: Double  // Auto-close timeout
}
```

### TranscriptionConfiguration

Transcription mode settings:

```swift
struct TranscriptionConfiguration {
    var transcriptionModeEnabled: Bool // Master toggle
    var hotkey: Hotkey?                // Global activation hotkey
}
```

### Language Support

Parakeet TDT v3 automatically detects and transcribes 25 European languages: English, German, Spanish, French, Dutch, Italian, Danish, Estonian, Finnish, Greek, Hungarian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Swedish, Russian, Ukrainian, Bulgarian, Croatian, and Czech.

Parakeet TDT v2 is optimized exclusively for English.

---

## Troubleshooting

### Voice Input Not Working

1. **Check microphone permission**

   - System Settings → Privacy & Security → Microphone → Enable Osaurus

2. **Verify model is loaded**

   - Open Voice settings
   - Ensure a model is downloaded and selected
   - Check that model loads without errors

3. **Test with audio level indicator**
   - Start voice input
   - Speak and watch the audio level visualization
   - If no level shown, check your audio device

### Low Transcription Accuracy

1. **Try the multilingual model**

   - Switch to Parakeet TDT v3 for broader language support

2. **Reduce background noise**

   - Use a closer microphone
   - Reduce ambient noise

4. **Adjust sensitivity**
   - Lower sensitivity if picking up background noise
   - Higher sensitivity if missing quiet speech

### VAD Not Detecting Wake-Words

1. **Check VAD is enabled**

   - Open Settings… (⌘,) → Voice → **Wake Word**
   - Verify **Enable Wake Word** is on

2. **Verify agents are enabled for VAD**

   - At least one agent must be selected
   - Or set a custom wake phrase

3. **Speak clearly**

   - Say the full agent name
   - Wait for detection (2-3 second cooldown between detections)

4. **Check the status indicators**
   - The Osaurus menu bar icon should show a blue pulsing dot (top-right) when VAD is listening
   - Click the menu bar icon and check the waveform button shows green

### System Audio Not Capturing

1. **Check macOS version**

   - Requires macOS 12.3 or later

2. **Grant Screen Recording permission**

   - System Settings → Privacy & Security → Screen Recording
   - Enable for Osaurus

3. **Restart after granting permission**
   - Permissions may require app restart

### Model Download Fails

1. **Check internet connection**

   - Models are downloaded from Hugging Face

2. **Verify disk space**

   - Large models need 3+ GB free space

3. **Check the download progress**

   - Downloads can take several minutes for large models

4. **Try a smaller model first**
   - Test with Tiny or Small model

### Transcription Mode Not Typing

1. **Check accessibility permission**

   - System Settings → Privacy & Security → Accessibility → Enable Osaurus
   - You may need to restart Osaurus after granting permission

2. **Verify the hotkey is set**

   - Open Voice settings → Transcription tab
   - Ensure a hotkey is configured

3. **Make sure a text field is focused**

   - Click into a text input before pressing the hotkey
   - Some applications may block simulated keyboard input

4. **Check the overlay appears**

   - If the overlay doesn't appear, the hotkey may conflict with another app
   - Try a different hotkey combination

5. **Verify microphone and model**
   - Same requirements as other voice features
   - Test voice input in chat first to confirm setup

---

## Privacy

All voice processing happens locally on your Mac:

- **No cloud transcription** — FluidAudio runs entirely on-device
- **No audio recording** — Audio is processed in memory only
- **No data collection** — Transcriptions stay on your machine
- **Neural Engine acceleration** — Fast, efficient processing

Your voice data never leaves your computer.

---

## Requirements

- **macOS 15.5+** for voice input
- **macOS 12.3+** for system audio capture
- **Apple Silicon** (M1 or newer) for optimal performance
- **Microphone access** permission
- **Screen Recording** permission (for system audio only)
- **Accessibility** permission (for Transcription Mode only)

---

## See Also

- [README.md](../README.md) — Project overview
- [FEATURES.md](FEATURES.md) — Complete feature inventory
- [Agents](../README.md#agents) — Create custom AI assistants


## Talk mode

**Voice → Talk Mode → Smart end of turn** is on by default when Smart Turn v3
is present. The app uses existing Hugging Face snapshots in place, or downloads
32 MB through the existing model transfer path into its auxiliary-model folder.
The detector sees the last eight seconds of 16 kHz audio, checks at 250 ms of
silence after at least 300 ms speech, and retries every 200 ms until the silence
deadline. Automatic silence defaults to 900 ms with the model and 700 ms without;
explicit saved silence values always win. Missing/failed models retain silence
behavior. Failed inference reports a notice and disables semantic checks until
Talk restarts. Stop, resumed speech, and rollover cancel/invalidate pending checks.
MLX inference runs off-main under the shared Metal gate; it can wait behind an
active GPU producer, while VAD and the silence deadline continue. The cached
model remains charged to the auxiliary residency ledger for its real lifetime.


In **Voice → Talk Mode**, enable the desired agent. Configure a speech model and
microphone in Voice Setup and a working provider in Text To Speech (load PocketTTS
before starting). Click the waveform-circle button beside the chat microphone, or
press **Control–Option–Command–T** globally. The shortcut uses the focused chat's
agent, falling back to the active agent and creating/focusing its chat window.
Press it again to stop. Closing/switching the owned chat also stops talk mode.

Talk mode continuously captures speech, uses Smart Turn when its local model is available, and waits for a final
transcript, and sends through the normal ChatSession lifecycle. Final ASR starts
speculatively after about 250 ms with Smart Turn (275 ms without it); renewed speech invalidates that
speculation, otherwise the result is reused at the configured endpoint. Speech shorter
than 300 ms and empty or filler-only “uh”/“um” turns are ignored. The first complete
assistant sentence is released to TTS immediately; after 500 ms without a sentence,
a clause of at least 40 characters ending in a comma/semicolon may be released.
Later sentences retain the normal grouping policy. Raw visible content is observed
before display pacing; reasoning remains on its existing separate channel.

With **Allow Barge-In**, speech must be sustained for at least 250 ms with active
Apple voice processing, or 300 ms without it (a larger saved minimum still wins).
Playback pauses tentatively, preserving queued audio and the reply's generation.
Final ASR confirms a real interruption before cancelling the reply. A rejected
self-transcript or failed/empty recognition resumes the paused reply. Capture
stays running, preserving the onset for the new turn. Reply epochs and capture segment IDs reject stale
callbacks. The indicator shows listening, hearing you, transcribing, thinking, or
speaking; **Show Captions** controls the partial user transcript.

**Echo Cancellation** requests Apple voice processing in a talk-only duplex
AVAudioEngine: microphone capture and TTS render through the same graph. If setup
succeeds, playback still raises VAD probability from 0.5 to 0.65; with AEC off
or unavailable the threshold is 0.75. Both elevated thresholds remain for 250 ms
after playback ends; real speech above the threshold is still accepted.
During playback, low-VAD frames learn a microphone RMS echo floor (EMA). A speech
frame needs both sufficient VAD probability and at least 2.5 times that floor.
A low-VAD estimate of speaker-to-microphone coupling also compares the concurrent
raw output RMS, so louder playback can raise the predicted echo floor. Both
meters use linear PCM, not the display meter. The floor resets per reply and
decays after playback. Constants are centralized in `TalkEchoPolicy`.
Final transcripts are compared with released/played agent sentences from the last
10 seconds. Normalized token substrings or >=60% overlap of the transcript's
unique tokens are rejected and counted in `echoRejectedSegments`. This heuristic
can also reject a user intentionally repeating the agent. Headphones can
help with difficult acoustic environments. A non-default microphone uses separate
capture and output engines with AEC disabled, keeping the default speaker; a
one-line notice explains the fallback. Route notifications coalesce for 300 ms
before rebuilding the graph and rescheduling pending audio. Only a failed rebuild
stops capture; a running graph with an unchanged input format is left alone.
System-audio input is not supported for talk mode. Dictation, wake-word, speaker-button, and tool speech keep
their existing engines when talk mode is off. Wake-word listening resumes if it
was running before talk mode. Continuous Chat Voice is stopped, not auto-resumed.

Settings save automatically. Changing **End of Turn Silence** or **Echo
Cancellation** stops capture and takes effect on the next start. Disabling the
active agent stops talk mode. **Think before speaking** (Voice → Talk Mode,
Off by default) applies to the next spoken send. Off uses the chat composer's
canonical `disableThinking` / `enable_thinking` mechanism only for a model with
a bundle-declared thinking toggle; On omits the override and uses the bundle
default. Talk turns do not inherit or modify the composer's saved reasoning
choices. Models without a toggle retain their native behavior; the caption
reports always-reasoning/non-reasoning, or unknown capability for remote models.
Other talk options apply immediately.

`TalkModeController.shared.latency` retains the last 50 sent turns as Codable
records. Stage fields are milliseconds from `speechEnd`, the monotonic capture
timestamp of the last VAD-positive frame:

- `endOfTurnDecidedMs`: the capture worker commits its semantic or silence endpoint.
- `smartTurnChecks`: attempted semantic checks (including cancelled/failed checks).
- `smartTurnProbability`: last accepted completion probability, absent if none completed.
- `endOfTurnReason`: `smartTurn` or `silence`; old records leave these fields absent.
- `asrFinalMs`: final ASR computation completes, even when speculative delivery
  is withheld until the endpoint. Speculation starts at 250 ms with Smart Turn (275 ms without it) on the
  next capture/VAD iteration; actual execution can wait for serialized ASR.
  Resumed speech cancels speculation and invalidates its timestamp. For joined
  segments, ASR/endpoint timings use the latest completion across all segments.
- `sendIssuedMs`: immediately before `ChatSession.send`.
- `firstStreamDeltaMs`: first stream event, including reasoning, tools, or metadata.
- `firstReasoningMs`: first nonempty reasoning delta; absent for direct answers.
- `firstVisibleTokenMs`: first nonempty raw content delta before display pacing;
  `firstTokenMs` is the retained compatibility alias, not a screen-paint measure.
- `firstSentenceReleasedMs`: first chunk queued to TTS (sentence, timeout clause,
  or final fragment); synthesis and playback have not necessarily started.
- `firstAudioMs`: first **completed** playback buffer, not acoustic onset.

`reasoningDeltaCount` counts nonempty reasoning deltas across tool continuations.
`reasoningDurationMs` sums phases from first reasoning delta to next nonempty
visible content or send completion/cancellation; it includes intervening waits,
not just decoder compute. A completed turn without reasoning has count/duration
zero and no `firstReasoningMs`. Missing measurements remain nil, including new
fields in older exports. `bargeInToStopMs` measures confirmed interruption to
synchronous null-sink stop; asynchronous hardware stops remain unmeasured.
`ai.osaurus` / `talk.mode` logs retain first-audio and null-sink stop timings.

These are software timings, not acoustic latency proof. The <1.2 s p50 first-audio
and <150 ms interruption targets require live measurement on the selected model,
provider, and devices. ASR finalization, VAD windowing, model warm-up, and the
configured silence interval all contribute to latency.

The gauge button beside the talk indicator opens the latency popover in Debug
and Release. It shows **Echo cancellation: On (Apple voice processing)** or
**Echo cancellation: Off — <reason>**, plus the rejected-echo count. VPIO errors
remain visible in the reason. `ai.osaurus` / `talk.audio` logs record the AEC
decision, device IDs, input rate/channels and VPIO errors at notice level. **Copy latency JSON** exports the in-memory samples to the clipboard.
Save them to a file and run `python3 fork/metrics/talk_latency.py turns.json` for
p50/p90 with measured/missing denominators. This exporter applies the same
nearest-rank percentile rule as the app and does not grade acoustic targets.
The T06 benchmark summary includes every stage, reasoning duration/count,
ordering errors, and measured ASR-before-endpoint counts. It marks runs PARTIAL
when required stages are missing or ordered inconsistently; reasoning onset is
only required when reasoning deltas were observed. Slow ASR may legitimately
finish after the endpoint, so that ordering is reported rather than fabricated.

A capture segment reaching two minutes finalizes and capture continues into a new
segment. Text from segments that finish ASR late is retained in order if the user
resumes speaking before submission. TTS, chat-turn, and ASR errors show a
toast and leave talk mode available for the next turn. External playback cancellation
ends the reply without ending capture. Speaker buttons, tab-switch stops, and the
`speak` tool do not replace active talk playback. A toggle received during teardown
queues a restart once teardown finishes.


### Residual-echo benchmark (T18)

The T06 launcher now retains baseline, barge-in, echo, and echo-plus-barge-in runs:

```sh
LABEL=t18 APP_SOURCE_SHA=<built-source-sha> fork/metrics/talk_bench.sh \
  /absolute/path/osaurus.app owner/model-folder /absolute/path/model-bundle
```

Direct file-input runs opt in with `OSAURUS_TALK_ECHO_DB=-20` and optional
`OSAURUS_TALK_ECHO_DELAY_MS=30` (0...1000 ms; requires ECHO_DB). Gain accepts
finite -60...0 dB. The paced null sink resamples its actual rendered 24 kHz TTS
PCM to 16 kHz, delays it, and adds it to capture even between user WAVs. Pause
preserves render buffers; cancellation drops them; already emitted echo drains.
This simulates residual echo, not Apple's VPIO or a physical room.

The completion sidecar reports `echoMixedSamples`, `echoRejectedSegments`,
`selfBargeIns` (confirmed cancellation without supplied user audio),
`tentativeSelfPauses` (temporary playback stops without supplied user audio),
and `echoSegmentsSent` (sends without supplied user audio). Input provenance is
tracked from unmixed WAV samples since the preceding send; it cannot distinguish
an echo transcript mixed with a simultaneous real user's speech. Transcript and
model output inspection are still required for overlapping speech.
The echo scenarios require actual mixed samples, zero self-barge-ins, zero
tentative self-pauses, zero echo sends, complete turn telemetry and exactly the
expected number of turns. Echo rejection counts may be zero if the acoustic gate
rejects all residuals. The real-user barge-in scenario must still show an actual
interruption. A two-second trailing observation period allows residual echo and
ASR to settle; timeouts and missing artifacts remain PARTIAL.
