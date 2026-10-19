---
title: Settings Overview
summary: Where every setting lives, and which ones the assistant can change for you.
order: 120
---

# Settings Overview

Settings… (⌘,) opens the Management window. Type a name in the sidebar search to jump to a control. The built-in assistant uses the same catalog via `osaurus_help` `{action: find}` — it will quote a breadcrumb, not invent a path.

Ask the assistant to change declarative settings in chat (`osaurus_config`); each change shows a one-tap approval card first (see the Declarative Configuration topic).

## Make it yours

After onboarding, an empty local chat shows **Make it yours**. Each row takes one click:

- **Talk to it** requests microphone access, enables the current agent in **Voice → Talk Mode → Enabled for Agent**, and prepares Parakeet (~600 MB) and PocketTTS through the existing download managers. Cached models are reused; your selected Parakeet version and any existing TTS provider/voice choices are preserved. New installs use on-device PocketTTS. Start talking with **⌃⌥⌘T** or the chat talk button once preparation finishes. Setup does not start recording. Downloads continue if you leave the chat. The card shows combined model preparation and each model's status; Parakeet and compilation may have indeterminate progress. A failure shows the manager's error; click the same button to retry. If microphone access is denied, allow Osaurus in macOS **System Settings → Privacy & Security → Microphone**, then retry.
- **Show your companion** enables **Conversation → Appearance → Show animated avatar**, including the floating desktop companion.
- **Reach it from your phone** opens **Server → Overview → Phone access**, scrolling to that control. Enable Phone access and finish the Tailscale login there. This shortcut never enables access silently; the row is done only when the phone service is running.

The card disappears when all three rows are ready. **Not now** hides it persistently across chats and launches; background downloads continue. Restore it with **Conversation → Appearance → Show Make it yours**. The three action labels are searchable aliases for their existing destination settings. Notification permission is requested after the onboarding window closes; users who have already completed onboarding retain the launch-time request.

## Agent descriptions

Each agent has an optional **Brief description (optional)** field under Settings → Agents → the agent → Configure. It is a one-line summary of what the agent does and when to delegate to it, shown beside the agent's name wherever the Orchestrator or an agent picker lists targets. It is never required: agents with a blank description can still be saved, duplicated, and delegated to.

When the description is blank and the agent has a system prompt, Osaurus generates a summary in the background (using the configured core model, or the model already loaded for chat) and shows it as the field's placeholder. Generation never blocks a save and never loads a model on its own; it runs after a chat turn completes or when the Orchestrator builds its delegation roster. Typing your own description overrides the generated one; editing the system prompt regenerates it. Description text is routing metadata and never grants tools or permissions.

## What the assistant can change in chat

- The Orchestrator (itself): display name, model, temperature, max output tokens, persona (system prompt).
- Memory: enabled, budget tokens, retention days.
- Agents: create/update custom agents, capability toggles, which agent new chats open with (`new_chat_agent`), and which built-in **Apple Apps** a custom agent may use (`capabilities.apple_apps`, e.g. `["calendar", "reminders"]`). The Orchestrator never calls the Apple app tools itself; ask it to "give Planner access to Calendar" or "create a Mail agent" and it patches or provisions the custom agent.
- Tools: global enablement and permission policies.
- Delegation: allowed subagents (custom agents and teammates' shared agents as `Name@Workspace`), per-workspace auto-join, spawn permissions, and the per-subagent limits (tokens, turns, seconds, local/remote parallelism).
- Plus everything else the declarative document covers: models, providers, MCP servers, plugins, commands, knowledge collections, channel routing, schedules, watchers, and web-search providers.

## What lives only in the Settings UI

- Server: port, expose to network, generation defaults, batching/concurrency, prefix/paged-KV/disk cache, **Context Window Cap**, KV retention, memory safety, model exposure. (Port and exposure changes restart the server; cache topology changes unload loaded models; disk-size changes update resident quotas.)
- Orchestrator: Settings → Orchestrator holds Identity, Model & Generation (with the **Model readiness** row), **Working Folder**, Subagents (**Allowed subagents**, **Create starter agents**, **Add all agents** — shown only while the list is empty but agents exist, **Permission**, **Permission for shared (workspace) agents**, **Limits**, **Advanced**, Local Models & Memory), and the **Delegations** list (Sent / Received). The working folder, model override, RAM-safety helpers and the Delegations list are UI-only; the rest is also declarative (`default_agent`, `delegation`).
- Conversation (Settings → Conversation): **Appearance** (Show animated avatar, Smooth Streaming, Group Thinking & Tool Activity, Check Spelling While Typing), **Behavior** (Automatically Name Chats, Suggest Follow-Up Questions, Clipboard Monitoring, ⌘+N Opens New Chat), **Agent Sessions** (Keep Mac Awake), and an **Advanced** disclosure with Show Thinking, the compaction model (unset = the chat's current model summarizes; compaction runs automatically near the context limit and on demand from the **Compact conversation** button in the chat's context budget popover or the `/compact` command; when set, this model summarizes every chat regardless of the chat's own model), Top P Override and Max Tool Attempts. **Not** the context window — that is Server → Cache.
- General: start at login, hide dock icon, appearance, global hotkey, Core Model, **Use models already on this Mac**, Show Notifications; **Advanced** holds the Models Directory, Model Sources, Max Concurrent Background Tasks, and **Data & Storage** (encryption, backup, file history). **Factory Reset…** sits at the very bottom.
- Voice: **Setup** (speech model, microphone, detection sensitivity), **Chat Voice** (voice input in chat), **Transcription** (system-wide dictation hotkey, stop behavior, cleanup), **Text-to-Speech** (voice, preview; engine under Advanced), **Wake Word**, and **Models**.
- Themes: theme gallery, custom theme editor, import/export. **Themes → Text & Fonts → Small body** sets the font size for compact controls and model lists (14 pt by default). Search for **Small body** to open the current theme in the editor and highlight its control. Built-in themes use **Save as Copy**; apply the saved copy from the gallery to use it. The chat model picker and Credits menu use Secondary Background and the default Border Color, Border Width, and Border Opacity controls under Borders & Effects; these controls are also available through Settings search.
- Computer Use / Browser / Sandbox: autonomy presets, app allowlists, resources.
- Permissions: macOS TCC grants (Accessibility, Screen Recording, …). Tool Auto/Ask/Deny policies and **Auto-Allow All Tool Calls** live under Tools & MCP → All Tools.
- Tools & MCP: **Services** (connected MCP services, **Add Service**, and the **Directory** of services you can add, filterable by category chips such as Legal, Finance & Accounting, and Healthcare & Life Sciences), **All Tools** (every tool with its permission policy), **Plugins** (native plugin registry).
- Images: **Defaults** (default generation and edit models, image/video job permissions, local and cloud video defaults; the **Image model load policy** is under Advanced) and **Image Models**.
- Mobile: **Generate Pairing Code** (a 6-digit code the Osaurus iPhone app redeems on the same network; one iPhone per Mac, pairing a new one unpairs the old), the **Paired iPhone** with **Unpair**, **Reach From Anywhere** (on by default; turns on the relay tunnel for every agent while a phone is paired, so the iPhone works away from this network, still end-to-end encrypted), and **Keep Mac Awake for Paired iPhone** (on by default; prevents idle system sleep only while a phone is paired).
- Privacy: **Filter** (the redaction filter, AI detection, per-provider overrides, background-request review, and Send Crash Reports), **Activity Log** (**Keep Activity History** retention, **Store Prompts and Responses**, **Review Activity in Insights**), **Rules**, and **Models** (the detection model).
  - Privacy → **Rules** has five sections: **Detection Patterns** (built-in phone — international and North American — email, URL and Luhn-valid card numbers), **My Regions** (the countries whose national ID / tax / health / bank presets are on by default; the first chip is detected from the Mac locale, **Add region…** opens a searchable picker over every country, removing a region never disables anything), **Preset Rules** (ready-made patterns grouped **My regions → Global → Other regions**, each group with **Enable all** / **Disable all**, a search field, and a **Suggested for …** banner when a home-region preset is off; US SSN is the `us.ssn` preset here, not a built-in), **Custom Rules** (**Add Rule**), and **Test Your Rules** (dry-run tester).
- Insights: the activity log / audit dashboard — every local or cloud interaction with a glance strip, scope tabs, filters, **Export** and (in its ⋯ menu) **Verify Integrity** / **Clear Activity Log**. Read-only; its retention and content policy are the Privacy → Activity Log controls above.
- Identity, General → Advanced → **Data & Storage** (encryption/backup, and **File History**: **Keep File History** — until the chat is deleted (default), 90 days, or 30 days — and **File History Size Limit**, which clears the oldest changes first but always keeps the most recent one; history that is cleared can no longer be reverted, and deleting a chat always deletes its file history), Channels credentials.
- Secrets of any kind (API keys, tokens) are always entered in native secure fields, never chat.

## Common names that are different controls

**Automatically Check Model Updates**, in Settings → Local Models, checks
metadata for installed official OsaurusAI Hugging Face models every six hours.
It is enabled by default and saved immediately. Turn it off to stop these
automatic checks; **Check for Model Updates** in a model's details remains a
manual action. Failures remain errors and retry with backoff. Checking never
downloads or replaces model weights. This switch is Settings UI only and is
separate from updating the Osaurus application.

| You might say | Actual control | Path |
|---|---|---|
| Context window / context budget / context length | Context Window Cap (tokens) | Settings… (⌘,) → Server → Settings → Cache → Context & KV Policy |
| Context budget (in chat) | Context Budget popover | Chat composer — read-only; Open Context Window Cap jumps to Server → Cache |
| Memory budget / token budget (memories) | Memory Budget | Settings… (⌘,) → Memory → Configuration |
| Max tokens (reply length) | Max Output Tokens | Settings… (⌘,) → Orchestrator → Model & Generation |
| Subagent limits / "agents end too fast" | Limits (Max output tokens per subagent, Max turns per subagent, Time limit per subagent) | Settings… (⌘,) → Orchestrator → Subagents → Limits |
| Orchestrator folder / file access | Working Folder | Settings… (⌘,) → Orchestrator → Working Folder (or the chat Folder chip) |
| Ask before delegating | Permission / Permission for shared (workspace) agents | Settings… (⌘,) → Orchestrator → Subagents → Permission |
| Max tokens (API defaults) | Generation Defaults → Max Tokens | Settings… (⌘,) → Server → Settings → Sampling Defaults |
| KV / cache window | KV Retention Override | Same Cache panel as the context cap |
| Audit log / activity history / "what was sent to the cloud" | Insights (dashboard) and Keep Activity History / Store Prompts and Responses (policy) | Settings… (⌘,) → Insights; Settings… (⌘,) → Privacy → Activity Log |
| Tool permissions | Could be Tools catalog, Chat folder tools, or macOS Permissions — ask `find` |
| Calendar / Reminders / Contacts / Notes / Mail / Messages / Maps / Music / Shortcuts access for an agent | Apple app groups in the tool picker (one group per app, toggled per app) | Settings… (⌘,) → Agents → *custom agent* → Abilities → Tools (declarative: `agents[].capabilities.apple_apps`) |
| Calendar / Contacts / Automation grant for the whole app | macOS permission | Settings… (⌘,) → Permissions (or the **Permission needed** badge on the app's group under Agents → Abilities → Tools) |

## Apple Apps (built-in)

Osaurus ships native tools for Calendar, Reminders, Contacts, Notes, Mail, Messages, Maps & Location, Music, and Shortcuts. They are **off by default** for every agent and are turned on per custom agent under **Agents → Abilities → Tools**, where each app is a group in the tool picker (Calendar, Reminders, …) listed above the plugin and MCP groups. The group's master checkbox — or any row switch, marked **Per app** — turns all of that app's tools on or off together; individual tools are not toggled separately. Turning an app on (in an existing agent or the Create Agent sheet) asks macOS for that app's permission right away (Calendar, Reminders, Contacts, Location, or Automation for Notes/Mail/Messages/Music; Messages reading needs Full Disk Access via System Settings). A denied grant does not flip the switch back — the group header shows a **Permission needed** badge; clicking it re-asks for any grant macOS can still prompt for and then opens the System Settings pane for whatever is still missing (Full Disk Access, or an Automation grant that was denied). Sending mail or messages and running deletes always show an approval card; "Allow for this run" never covers them. The Default agent (Orchestrator) has no Apple app groups in its picker and never calls these tools; it manages them on custom agents through `osaurus_config` (`capabilities.apple_apps`, the full list replaces the set, `[]` turns all off) and can provision a new agent with apps in the same call. The former `osaurus.calendar` / `.reminders` / `.contacts` / `.notes` / `.mail` / `.messages` / `.maps` / `.music` plugins are superseded by these built-ins.

Unknown-Model Metadata Fallback on the same Cache panel does **not** constrain local models. Use Context Window Cap to lower the window.

## Delegation memory checks

**Swap local models for subagents**, under Settings → Orchestrator → Local
Models & Memory, is shared by custom agents and the Orchestrator. It applies
to local text delegation (including batches, background and resumed children),
Browser Use, Computer Use and dedicated AppleScript calls. On swaps the exact
invoking model out and restores it after the child. AppleScript's separate
keep-warm policy can defer that restoration for back-to-back calls; changing
the swap or warm setting settles the previous lease before the next run.

Off keeps the exact invoking model resident for the child's lifetime, including
under Server Strict. Only that job's newly loaded child is cleaned up afterward;
an already-resident shared target is not evicted. Memory checks may refuse a child,
but never fall back to evicting the parent. The redundant experimental coexistence
switch was removed; its old configuration key is retained only for compatibility.
If the parent was already unloaded, Off does not reload it. Same-model
and remote children do not need a swap. Local image jobs and context compaction
use this same parent-swap setting. The image Load policy controls only image-model
cleanup after the job; restoring a swapped parent always drains and unloads the
image model first. Independent scheduled/watch jobs and background helpers do
not gain permission to evict unrelated chat models from this switch. A scheduled
or watched agent's nested delegation uses that job's own invoking model.

Settings → Orchestrator → **Local Models & Memory** → **Check memory before delegating**
is one shared setting for the Orchestrator and all custom agents, not a per-agent override.
It defaults to On. It budgets child state, reuses already-resident weights, and can
split a batch or refuse a child under low headroom or elevated memory pressure.
Reclamation waits for active GPU work to drain and then takes a fresh host sample;
another delay cannot guarantee that the OS pressure or available bytes will change.

Off bypasses delegation RAM admission and before/after-handoff memory preflights,
including warning/critical pressure and unavailable estimates. Allocation failures
or crashes remain possible. Permissions, model ownership, cancellation and explicit
concurrency limits still apply. Server → **Memory Safety** load budgets are separate;
**No Automatic Limits (Dangerous)** removes automatic load caps there, while explicit
advanced overrides remain in force. Disabling the delegation check does not silently
rewrite those server settings. Decisions report `ram_safety_enabled`; when false,
`ram_slots` is diagnostic and does not limit the admitted capacity.

## Native MTP

Speculative Decoding defaults to **Default**, which resolves from the selected
bundle. Qwen Flash-Next bundles with a usable native MTP head start **On
(Adaptive)**, including supported affine and JANGH variants. Qwen 27B uses a
compatible bundled DFlash2 drafter automatically when one is present. A bundle
without compatible draft support runs ordinary autoregressive decoding.

The model picker shows **Off (AR)** or **On (Adaptive)** before weights load.
The runtime chooses depth; there are no manual D1/D2/D3 buttons. Explicit Off
turns speculation off, including external and bundled drafters. Saved explicit
choices survive reload. Legacy manual depths migrate to Adaptive and are
re-evaluated by runtime admission. **Reset to default** restores the selected
bundle's policy, so a capable bundle can show Adaptive again. Included evaluations
and benchmarks inherit that policy unless explicitly overridden.

On is a request, not proof that a particular request uses speculation. Unsupported
media and schema-constrained requests run AR. Server → Settings → **Speculative
Decoding** shows the loaded model's actual resolution and reason. Sampling stays
bundle-driven unless explicitly overridden. Remote models do not expose this
local control.

## Local model memory

Server → Settings → Model Memory contains **Keep Model Loaded** (off by
default) and **Unload After** (30 seconds by default). Models load when you
send a request. With Keep Model Loaded off, idle weights unload after the
timeout, or immediately when their last chat window closes. Active requests
finish first; another open window or active background/API request is protected.
Closing a chat does not shorten an unrelated API client's timeout.

Enable Keep Model Loaded to retain weights across idle time and window close.
Manual unload, model switching, changing settings that require a reload, and
quitting can still unload them. Saving a residency change also updates models
already idle in memory. This setting is UI-only, not declarative chat config.
An older 15-minute default migrates once to 30 seconds; other saved durations
and explicit Keep Model Loaded choices remain unchanged.

macOS manages swap. Osaurus no longer shows swap warnings or requires a
“Use Anyway” confirmation. Actual model-load failures still appear normally.

## Management sidebar

General, Conversation, Voice, Themes, Credits, Workspaces, Mobile, Identity, Permissions, Privacy, Local Models, Providers, Images, Orchestrator, Agents, Channels, Web Search, Knowledge, Memory, Tools & MCP, Skills, Commands, Schedules, Watchers, Computer Use, Browser Use, Server, Sandbox, Insights.

Older names still resolve: the former **Chat** tab is now **Conversation**, **Media** is **Images**, **Tools** is **Tools & MCP**, and the separate **Storage** tab (encryption, backup, file history) now lives under General → Advanced → Data & Storage. The Command Line Tool installer moved to Server → Overview.

## Where settings are stored

Config JSON lives under `~/.osaurus/config/` (`server.json`, `server-runtime.json`, `chat.json`, `default-agent.json`, `agent-delegation.json`, `memory.json`, …). Secrets live in the macOS Keychain.

### SSD cache controls

Normal cache filling and eviction are silent. Cache state is available in the
context-budget popover and Live Activity; there is no inline capacity-notice
popup or suppression setting.

**Clear SSD Cache** remains available in Cache settings and removes indexed
conversation cache files and linked companion data. Chats and model weights are
preserved. Clearing can make the next reply slower while cached data rebuilds;
it does not increase the cache limit. Save directory changes before clearing the
SSD cache; Clear is disabled while the displayed directory differs from the saved
directory. Clearing remains available when prefix reuse is disabled.

Disk Cache Size left blank uses **Automatic**: 30% of free space plus the cache's indexed payload bytes, including companions. Cache growth therefore does not shrink its own quota. An explicit percentage remains a percentage of total volume size, bounded by 25% of free space plus this cache; Settings shows the requested and effective amounts when limited. Existing percentages and legacy GB choices are preserved. Editing the percentage field replaces a legacy GB choice; clearing an explicit percentage selects Automatic. For a saved legacy GB choice, click **Use Automatic Cache Size**, then Save Changes.

Saving only the disk size updates resident models without unloading their weights. A decrease is enforced at the next cache write. Low free space produces an advisory and does not silently disable caching. Prefix Cache remains the master reuse switch; with paged RAM off, SSD reuse can still operate independently.

Cache controls are individually searchable: **Prefix Cache**, **Enable GPU Cache**,
**Block Size (tokens)**, **Max Blocks**, **Disk Cache**, **Disk Cache Directory**,
**Disk Cache Size (% of disk)**, **Clear SSD Cache**,
and **Re-derive SSM State After Generation**. Each result opens Server → Settings
→ Cache and scrolls to that control. Prefix Cache controls all reuse; Enable GPU
Cache controls the optional RAM tier, Disk Cache controls SSD reuse, and the
SSM option retains architecture-specific companion state for hybrid models.

### Concurrency and prompt processing

- **Server → Concurrency & Batching → Concurrent Sessions** sets the shared BatchEngine ceiling for same-model local jobs and local subagents. Continuous Batching must be on for concurrent decoding. Memory Safety overrides and current occupancy can reduce the effective limit displayed below the field; an empty override uses the Memory Safety profile.
- **Server → Concurrency & Batching → Prompt Prefill Chunk Size** sets how many prompt tokens are processed per prefill step. Empty uses the engine default. This is not the context window or the response token limit.

Search settings or ask Settings Help using either exact control name to navigate directly to it.

### Upscale an image

In **Images → Models**, choose **Upscale** beside an installed SeedVR2 3B bundle.
Select a source image, choose **Scale** (2× or 4×), and optionally enter a seed.
SeedVR2 preserves the source aspect ratio and runs its fixed one-step restoration.
Cancel stops cooperatively; the image lane remains held until the producer drains.

### Image sampling controls

In **Images → Image Models**, open **Generate** or **Edit** for an installed local bundle. **Sampler** and **Scheduler** list the choices supported by that bundle; **Bundle default** preserves its native behavior. **Timestep shift** appears only when the bundle supports an override. Leaving it empty preserves the default. Turbo bundles with a fixed sampling schedule reject alternate schedules or shifts. The same optional `sampler`, `scheduler`, and `shift` fields are accepted by the local image API and image tool; unsupported provider requests fail instead of silently dropping them.

**Live previews** in the local Generate/Edit panel shows an optional small image every five denoising steps. API/tool callers can set `preview_interval` and `preview_max_pixel`. Previews are off by default, may be dropped when busy or under memory pressure, and never replace the saved final image.

### Keeping model weights resident

Server → Memory Safety → **Keep Model in Memory** requests GPU residency while a local model is loaded. It is on by default when the model fits the GPU working-set ceiling and the OS reserve. Other apps may slow down because wired pages cannot be reclaimed. Turning it off permits the OS to evict model pages, which can slow replies under memory pressure. Saving changes reloads the model before its next request. This setting does not change **Keep Model Loaded** or the idle unload timer. A model that does not fit still loads in Safe Auto with an advisory; Strict retains its admission checks.

### Animated agent avatar

In **Settings → Conversation → Appearance**, turn on **Show animated avatar** (off by default). This immediately shows a floating dinosaur companion and replaces empty-chat hero avatars with the animated character. Drag the floating companion to reposition it; its position survives relaunch. Click it to start or stop talking with the last active agent without opening chat. Enable the agent in **Voice → Talk Mode** and configure speech input/output first. The **⌃⌥⌘T** shortcut also talks through the companion while it is visible. Right-click (or Control-click) for **Open chat**, **Hide companion**, and agent switching. Hiding the companion stops talk mode started from it. Turn the same toggle off to hide it and restore static avatars, including custom images. The character uses the agent’s mascot color (blue when none is selected), with a scarf, glasses, or leaf for the selected mascot.

When **Show animated avatar** is on and the detected agent is enabled in **Voice → Talk Mode**, its wake word starts companion talk without raising chat. Otherwise wake detection keeps the existing chat-window behavior. Ending companion talk resumes wake listening if Wake Word remains enabled.

The companion grows while talk mode is active, perks up while listening, and looks upward while waiting for speech playback. Your partial transcript appears while listening when **Voice → Talk Mode → Show Captions** is enabled. It briefly celebrates completed replies, looks apologetic after talk errors, and reacts when interrupted. At rest it occasionally looks around, stretches, or wags its tail, and loosely follows the pointer with its eyes. Reduce Motion disables idle motion, pointer following, and animated resizing while retaining a level-driven mouth and static expressions. Hidden or occluded surfaces stop animating and sampling.

### Server → Overview → Phone access over Tailscale

**Phone access** is off by default. Enable it to start the local HTTP server and
its bundled `osaurus-ts` helper. **Sign in to Tailscale** opens the helper's
interactive login URL; authenticate once, then scan the phone URL QR code with a
phone on your tailnet. The node (`osaurus-<random 6 hex>`) persists across restarts.
The random name is persisted in the phone-access state directory and avoids putting
your Mac hostname in certificate transparency logs. This path does not use
`agent.osaurus.ai` or automatic port mapping. HTTP listens only inside the tailnet;
while enabled, tsnet also opens a host UDP WireGuard socket.

**Allowed Tailscale logins** is a comma-separated list of tailnet login names.
Empty means the login that authenticated the node. **Every device signed in to
an allowed login receives owner access**, including the built-in agent, unless
you restrict devices. We recommend a tailnet ACL to limit devices that can reach
this node. **Save allowed logins** applies immediately
by restarting the helper and rotating its launch secret. Disable **Phone access**
to stop the helper; the tailnet node state is retained for next time.

**Connected devices** lists the name, StableID, login and last allowed/denied
request for devices that have opened the phone URL. Names are display-only;
selection uses the authenticated Tailscale StableID. Enable **Restrict access to
selected devices**, select the devices, then press **Save device restrictions**.
An empty selection with restrictions enabled denies all devices. Devices must
also belong to an allowed login. Saving restarts the helper, closes existing
connections and rotates its capability. Device discoveries, selection and the
restriction toggle persist across relaunches. Restrictions default off. Last
request status is historical, not a promise of current access.

The helper rejects unknown Host names (including DNS rebinding), cross-origin
requests and Sec-Fetch-Site values other than absent, same-origin or none. Phone
responses do not grant cross-origin browser access. Only one app instance can
hold the phone-access state directory lock at a time.

**Allow phone to view this Mac's screen** is a separate, off-by-default switch
in this card. Only devices signed in as the **tailnet node owner** can view the
screen; other allowed logins can still chat. It saves immediately, resets to off
when Phone access is turned off, and expires after **7 days unused**. Enabling it
starts that interval; only a successful frame renews it. The card shows the
expiry date. Relaunch preserves only an unexpired grant (old grants without a
timestamp must be enabled again). The card shows the Screen Recording state; **Open Screen Recording
Settings** opens the macOS pane. Grant Osaurus permission there (a relaunch may
be required). Screen viewing does not grant Accessibility or enable Computer Use.

On the phone, choose **Screen** to view the Mac's main display. Tap the preview
to enlarge and scroll it; use the browser's pinch zoom for detail. The page polls
only while this panel and the page are visible. Returning to **Chat**, hiding the
page, or leaving it aborts polling and clears the preview. The Mac displays
**Phone is viewing your screen** in the menu bar and in a floating overlay on the
active display. These expire about five seconds after the last frame. A user
notification is posted on the first successful frame per device/session and after
an idle gap longer than 60 seconds; delivery follows macOS notification permissions.
Turning off screen viewing or stopping Phone access removes both indicators
immediately and discards pending captures.

Screen capture requires a working durable Insights store. A metadata-only
“screen view started (device …)” row must be committed before the first capture;
ongoing sessions write at most one summary per minute with the preceding interval's
frame and byte counts. These are session summaries, not exact per-frame receipts.
Unavailable storage or append failure stops viewing with `audit_unavailable`.
Unverified requests are rejected before the main actor and counted in at most one
aggregate rejection row per minute. Verified rejection rows (including rate limits)
are capped at one per device per minute. Pixels are not stored in Insights or chat
artifacts.

**Ask about this screen** uses the selected agent's normal streamed chat. In the
Screen panel the picker lists only custom agents with effective **Tools** and
**Computer Use** enabled; if none exist, it explains how to configure one on the
Mac. Reload the page after changing agents. Tool-completion events refresh the
preview, and polling shows changes during longer tools. The preview itself is
not attached to messages: the agent uses its existing Computer Use perception
and cloud-vision consent rules. All actions keep the normal approval gate. Keep
a Mac chat window open for approval cards; this browser panel does not add a
remote approval surface. A run requiring approval without a Mac presenter fails
with the existing clear error. No phone click, key or pointer input is injected.
Screen viewing accepts only helper-verified owners; API keys, the public relay
and ordinary loopback callers cannot fetch it, even when they can use chat.

The phone companion uses the selected agent’s mascot color and accessory, or its custom image with an audio-reactive ring. Tap the small header companion to start talk; it grows in the center with playback-synchronized sentence captions. Tap it again to interrupt and end talk. Reduce Motion keeps a static pose and simple mouth; hiding the page stops animation and talk.

The phone page supports an agent picker, streaming chat, safe basic Markdown,
and Hold to talk using the Mac's `/audio/transcriptions` endpoint (configure a
speech model on the Mac first). **Speaker on** speaks replies through
`/v1/audio/speech` using the Mac's enabled **Voice → Text To Speech** provider;
download/load PocketTTS or configure the OpenAI-compatible provider first.
**Talk mode** loops through Listening, Thinking and Speaking. Tap **End talk /
Interrupt** or **Stop** to stop audio and the current turn. It listens again only
after playback finishes; voice barge-in is not supported. These phone controls
are session-only and start off after reload. The first tap unlocks iOS audio.
HTTPS uses tailnet certificates; when unavailable, HTTP still travels inside
Tailscale but browser microphone and PWA features require HTTPS. The page explains
this limitation. On iOS Safari, use Share → Add to Home Screen.
A missing helper requires a build with Go (`make app`); no helper is downloaded at
runtime. Team-signed apps require a valid helper signature from the same Team ID.
Ad-hoc/development apps require the SHA-256 compiled into Swift by `make ts-helper`
**before** app compilation (`make app` handles this order). The checked-in pin is
nil, so unprepared development builds fail closed. Sidecars are not trusted.
Builders signing with a team must set `TS_HELPER_SIGN_IDENTITY` to that app's
identity and sign/seal the final app bundle after embedding. Helpers that are
symlinks or group/world-writable are refused, and integrity is rechecked immediately
before launch. The launch secret travels over stdin, never the child environment.
If a helper exits, the status shows the error; toggle off/on to retry.


### Voice → Talk Mode

- **Enabled for Agent** — opt individual agents into hands-free conversation.
- **End of Turn Silence** — silence before sending a final transcript (700 ms by default).
- **Allow Barge-In** — sustained speech interrupts generation and playback (160 ms minimum).
- **Echo Cancellation** — request Apple voice processing on the shared microphone/playback engine.
  If unavailable, playback uses a higher VAD threshold and a 300 ms echo cooldown.
- **Show Captions** — display the user's partial transcript beside the chat talk button.

Settings save automatically. Silence and echo changes stop active talk mode; start it again
for the new capture settings. Toggle with the waveform circle beside the chat mic or
**Control–Option–Command–T**. Talk mode pauses Wake Word and supersedes continuous Chat Voice.
It requires a microphone input, downloaded speech model, and configured Text To Speech engine.


On Macs with **16 GB of RAM or less**, starting Talk checks the combined chat,
speech, and loaded privacy-model estimate against the existing comfortable model
budget (85% of the GPU working-set budget) and measured host headroom with the
existing 3 GiB reserve. If tight, **Talk mode memory** recommends a smaller chat
model and explains when room is also needed for the privacy filter. This is an
advisory, not a new load limit: Talk continues and the existing runtime limits
still apply. No privacy setting, model default, or memory limit changes automatically.
Larger Macs do not show this advisory. An unavailable estimate is reported explicitly.

Speech estimates use the loaded compiled artifacts' on-disk bytes × 1.25 for
runtime state, not a measured physical footprint. STT, VAD, and local TTS remain
counted while their engines are cached, including after Talk or voice input stops;
only releasing the actual engines removes them. Remote TTS adds no local model,
but switching to it does not unload an already cached local engine. Available host
memory already reflects resident engines, the embedder, image workloads, and the
sandbox VM, so those resident bytes are not subtracted from that sample again.
