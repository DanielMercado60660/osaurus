# T04b — Phone access security hardening

Read `fork/tasks/CODEX_PREAMBLE.md`, `AGENTS.md`, then
`fork/tasks/T04-tailscale-phone.RESULT.md`. A security review of T04 found no
allowlist bypass but the issues below. Fix all of them. Paths: helper in
`helpers/osaurus-ts/`, Swift under `Packages/OsaurusCore/`.

## F1 (medium) — DNS rebinding against the plain-HTTP fallback

`main.go` compares `Origin` to `r.Host`, but Host is attacker-controlled and is
never checked against the node's own names. A page on `evil.com` that rebinds
to the node's 100.x IP, opened on any of the owner's tailnet devices, passes
WhoIs (the owner's device) and gets owner trust over HTTP.

Fix:
- In `run()` build the set of acceptable hosts: the cert domain(s), `Self.DNSName`
  without trailing dot, the short MagicDNS name, and the node's tailnet IPv4/IPv6
  literals. In `authorize`, reject (421 or 403) any request whose Host
  (lowercased, port stripped, IPv6 brackets handled) is not in the set.
- Require `Sec-Fetch-Site` to be absent, `same-origin` or `none`.
- In `HTTPHandler.swift` (~4228) do not send `Access-Control-Allow-Origin: *`
  for requests carrying the phone marker header.
- Go tests: rebinding Host rejected; each legit host form accepted; IPv6;
  `Sec-Fetch-Site: same-site|cross-site` rejected.

## F2 (medium, design) — per-login trust covers every device on that login

Add an optional **device allowlist**: the status stream reports the requesting
node (StableID + name) for denied/allowed requests; the settings card lists
devices that have connected and lets the owner restrict access to selected
devices (default: all devices of allowed logins, as today). Enforce in the
helper using `who.Node.StableID`. Update the settings text to say plainly that
access applies to every device signed in to the allowed login unless devices
are restricted, and recommend a tailnet ACL. Settings-catalog rules apply.

## F3 (low) — helper integrity pin is a sidecar file

Replace the sidecar check with code-signature validation: use
`SecStaticCodeCreateWithPath` + `SecStaticCodeCheckValidity` and require the
helper's Team ID to equal the main app's Team ID (read the app's own signing
info). For ad-hoc/dev builds with no Team ID, fall back to comparing the
helper's SHA-256 against a digest **compiled into the Swift binary** at build
time (generate a small Swift source in the Makefile `ts-helper`/`app` flow, or a
build-setting-injected constant) rather than a sidecar. Also refuse to launch a
helper that is group/world-writable. Launch from a validated file descriptor or
re-validate immediately before launch to narrow TOCTOU.

## F4 (low) — launch secret in the child environment

Pass the secret as the first line on the helper's stdin (already held open for
EOF detection) and read it in `run()` instead of `os.Getenv`. Remove the env
var. Test the parse in Go.

## F5 (low)

- Fix the `main.go:1` comment: tsnet opens a UDP WireGuard socket while
  enabled. Disable the port mapper if tsnet v1.94.2 supports it
  (`TS_DISABLE_PORTMAPPER` or the tsnet/ envknob equivalent — verify in the
  module source under the Go module cache; skip if not supported and say so).
- Node name: `osaurus-<random 6 hex>` generated once and persisted in the
  state dir, instead of the Mac hostname (which would land in Certificate
  Transparency logs).
- `Resources/Phone/phone-app.js`: show the link host next to markdown link
  text (e.g. `Apple ID login (evil.example)`), still via `textContent`.

## F6 (info)

Take an exclusive `flock` on the tsnet state directory in `run()`; if held,
emit an `error` status ("another Osaurus instance is using phone access") and
exit non-zero.

## Done

`go test -race ./...` and `go vet` pass in the helper; Swift pure-logic tests
updated; commit on your branch; write `fork/tasks/T04b-phone-access-hardening.RESULT.md`
listing each finding → fix → test.
