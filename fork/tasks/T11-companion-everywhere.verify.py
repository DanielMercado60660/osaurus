#!/usr/bin/env python3
"""Isolated production talk controller + pure routing tests with inert services.
No model, microphone, keychain, network, or app windows. Not Release proof.
"""
import os
from pathlib import Path
import runpy
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
runpy.run_path(str(root / 'fork/tasks/T03-talk-mode.verify.py'))
dest = root / 'build/T11/Proof'
shutil.copytree(root / 'build/t03-harness', dest, dirs_exist_ok=True, ignore=shutil.ignore_patterns('.build'))
src = dest / 'Sources/OsaurusCore'
tests = dest / 'Tests/OsaurusCoreTests'
core = root / 'Packages/OsaurusCore'
shutil.copy(core / 'Services/Voice/WakeWordRoute.swift', src)
shutil.copy(core / 'Tests/Voice/WakeWordRouteTests.swift', tests)
p = src / 'ProofStubs.swift'
s = p.read_text().replace('"/tmp/osaurus-t03-proof-only"', '"' + str(root / 'build/T11/test-config') + '"')
s = s.replace('    func windowState(id: UUID) -> ChatWindowState? { nil }', '''
    private var states: [UUID: ChatWindowState] = [:]
    var createdShowFlags: [Bool] = []
    var shownIDs: [UUID] = []
    func reset() { states = [:]; createdShowFlags = []; shownIDs = []; lastFocusedWindowId = nil }
    func windowState(id: UUID) -> ChatWindowState? { states[id] }
''')
s = s.replace('func findWindows(byAgentId id: UUID) -> [WindowInfo] { [] }', 'func findWindows(byAgentId id: UUID) -> [WindowInfo] { states.values.filter { $0.activeAgent.id == id }.map { WindowInfo(id: $0.windowId) } }')
s = s.replace('func createWindow(agentId: UUID, showImmediately: Bool = true) -> UUID { UUID() }', '''@discardableResult func createWindow(agentId: UUID, showImmediately: Bool = true) -> UUID {
    let state = ChatWindowState(); states[state.windowId] = state
    createdShowFlags.append(showImmediately)
    if showImmediately { showWindow(id: state.windowId) }
    return state.windowId
}''')
s = s.replace('func showWindow(id: UUID) {}', 'func showWindow(id: UUID) { shownIDs.append(id) }')
s = s.replace('    func pause() async {}', '    func pause() async { state = .idle }')
s = s.replace('    func resumeAfterChat() async {}', '''    var resumeAttempts = 0
    var resumeCount = 0
    var delayResume = false
    var resumeGate: CheckedContinuation<Void, Never>?
    func resumeAfterChat() async {
        resumeAttempts += 1
        if delayResume { await withCheckedContinuation { resumeGate = $0 } }
        // Mirror the real guard that previously rejected stop-time resumption.
        guard !TalkModeController.shared.isActive else { return }
        resumeCount += 1; state = .listening
    }''')
s = s.replace('    let subject = PassthroughSubject<TalkCaptureEvent, Never>()', '    var failStartup = false\n    let subject = PassthroughSubject<TalkCaptureEvent, Never>()')
s = s.replace('async throws -> Bool { false }', 'async throws -> Bool { if failStartup { throw NSError(domain: "Proof", code: 1) }; return false }')
p.write_text(s)
# The new tests extend the existing serialized suite so singleton spies never race.
(tests / 'CompanionBindingTests.swift').write_text(
    (root / 'fork/tasks/T09-companion-conversation.binding-tests.swift').read_text()
    + '\n' + (root / 'fork/tasks/T11-companion-everywhere.binding-tests.swift').read_text())
env = os.environ.copy()
env.update(GIT_TERMINAL_PROMPT='0', GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='credential.helper', GIT_CONFIG_VALUE_0='',
           CLANG_MODULE_CACHE_PATH=str(root / 'build/ModuleCache'), SWIFTPM_MODULECACHE_OVERRIDE=str(root / 'build/ModuleCache'),
           OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS='1', OSAURUS_TEST_ROOT=str(root / 'build/T11/test-root'), OSU_MODELS_DIR=str(root / 'build/T11/test-models'))
for key in list(env):
    if key.startswith('OSAURUS_TALK_'): del env[key]
command = ['swift', 'test', '--disable-keychain', '--disable-sandbox', '--build-system', 'native',
           '--package-path', str(dest), '--cache-path', str(root / 'build/swiftpm-cache'),
           '--config-path', str(root / 'build/swiftpm-config'), '--security-path', str(root / 'build/swiftpm-security'), '--jobs', '4']
print('Running:', ' '.join(command), flush=True)
with (root / 'build/T11/isolated.log').open('w') as output:
    result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
print('Tests exit:', result.returncode, flush=True)
raise SystemExit(result.returncode)
