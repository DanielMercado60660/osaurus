#!/usr/bin/env python3
"""Compile actual avatar/talk sources with inert app seams; render contact sheet.
No microphone, model, keychain or live app. This is NOT integrated Release proof.
"""
import os
from pathlib import Path
import runpy
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
runpy.run_path(str(root / "fork/tasks/T03-talk-mode.verify.py"))
dest = root / "build/T09/Proof"
shutil.copytree(root / "build/t03-harness", dest, dirs_exist_ok=True, ignore=shutil.ignore_patterns(".build"))
src = dest / "Sources/OsaurusCore"
core = root / "Packages/OsaurusCore"
for folder in ["Services/Avatar", "Views/Agent"]:
    for path in (core / folder).glob("*.swift"):
        if folder == "Services/Avatar" or path.name in ["LiveAgentAvatarView.swift", "AnimatedAgentAvatarView.swift"]:
            shutil.copy(path, src)
for path in (core / "Tests/Avatar").glob("*.swift"):
    shutil.copy(path, dest / "Tests/OsaurusCoreTests")
shutil.copy(core / "Tests/Voice/TalkBenchmarkTests.swift", dest / "Tests/OsaurusCoreTests")
# The production mascot catalog (no bitmap renderer or unrelated avatar views).
mascot = (core / "Views/Agent/AgentAvatarView.swift").read_text()
(src / "AgentMascot.swift").write_text("import SwiftUI\n" + mascot[mascot.index("public enum AgentMascot:"):mascot.index("/// Renders an agent avatar")])
p = src / "ProofStubs.swift"
s = p.read_text()
a = s.index("// T09 presentation boundary;")
b = s.index("@MainActor final class ToastManager", a)
s = (s[:a] + s[b:]).replace("enum Role { case assistant }", "enum Role { case assistant, user }; var role = Role.assistant; var visibleContent: String { content }")
s = s.replace("struct Agent: Identifiable {", 'struct Agent: Identifiable, Equatable { var avatar: String? = "green"; static let `default` = Agent(id: defaultId, name: "Default");')
s = s.replace("    var agents: [Agent]", "    var activeAgentId: UUID { activeAgent.id }; func setActiveAgent(_ id: UUID) {}\n    var agents: [Agent]")
s = s.replace("    var isAvailableForDispatchReattachment = true", "    var agentId = Agent.defaultId; var isStreaming = false; var turns: [ChatTurn] = []\n    var isAvailableForDispatchReattachment = true")
s = s.replace("    var lastFocusedWindowId: UUID?", "    @Published var lastFocusedWindowId: UUID?\n    func windowId(for window: NSWindow) -> UUID? { nil }")
s = s.replace("enum State { case idle, starting, listening }", "enum State { case idle, starting, listening, error }; var audioLevel: Float = 0")
s = s.replace("    let subject = PassthroughSubject<TalkCaptureEvent, Never>()", "    var isSpeechDetected = false; var audioLevel: Float = 0\n    let subject = PassthroughSubject<TalkCaptureEvent, Never>()")
s = s.replace("    let isModelReady = true", "    var playingMessageId: String?; var outputLevel: Float = 0\n    let isModelReady = true")
s = s.replace('"/tmp/osaurus-t03-proof-only"', '"' + str(root / 'build/T09/test-config') + '"')
# Inert window/session spies exercise the actual controller binding branches.
s = s.replace("    func windowState(id: UUID) -> ChatWindowState? { nil }", """
    private var states: [UUID: ChatWindowState] = [:]
    var createdShowFlags: [Bool] = []
    var shownIDs: [UUID] = []
    func reset() { states = [:]; createdShowFlags = []; shownIDs = []; lastFocusedWindowId = nil }
    func windowState(id: UUID) -> ChatWindowState? { states[id] }
""")
s = s.replace("func findWindows(byAgentId id: UUID) -> [WindowInfo] { [] }", "func findWindows(byAgentId id: UUID) -> [WindowInfo] { states.values.filter { $0.activeAgent.id == id }.map { WindowInfo(id: $0.windowId) } }")
s = s.replace("func createWindow(agentId: UUID, showImmediately: Bool = true) -> UUID { UUID() }", """@discardableResult func createWindow(agentId: UUID, showImmediately: Bool = true) -> UUID {
        let state = ChatWindowState(); state.session.agentId = agentId; states[state.windowId] = state
        createdShowFlags.append(showImmediately)
        if showImmediately { showWindow(id: state.windowId) }
        return state.windowId
    }""")
s = s.replace("func showWindow(id: UUID) {}", "func showWindow(id: UUID) { shownIDs.append(id) }")
p.write_text(s)
shutil.copy(root / "fork/tasks/T09-companion-conversation.binding-tests.swift", dest / "Tests/OsaurusCoreTests/CompanionBindingTests.swift")
# Keep the probe in the same module to render internal production views.
(src / "AvatarContactSheet.swift").write_text('''import AppKit
import SwiftUI
@MainActor public func renderAvatarContactSheet(to path: String) throws {
    let moods: [AvatarMood] = [.idle, .listening(0.7), .thinking, .speaking(0.8), .error]
    let sheet = VStack(spacing: 14) {
        Text("Companion — moods, reactions and accessories").font(.title2)
        HStack {
            ForEach(Array(moods.enumerated()), id: \\.offset) { _, mood in
                VStack {
                    DinosaurAvatarRenderer(mood: mood, tint: .blue, time: 1, reduceMotion: true).frame(width: 160, height: 160)
                    Text(mood.accessibilityDescription)
                }
            }
        }
        HStack {
            ForEach(AvatarReaction.allCases, id: \\.self) { reaction in
                VStack {
                    DinosaurAvatarRenderer(mood: .listening(0.4), tint: .orange, time: 1, reduceMotion: true, reaction: reaction).frame(width: 180, height: 180)
                    Text(reaction.rawValue)
                }
            }
        }
        HStack {
            ForEach(AvatarAccessory.allCases, id: \\.self) { accessory in
                VStack {
                    DinosaurAvatarRenderer(mood: .idle, tint: .green, time: 1, reduceMotion: true, accessory: accessory).frame(width: 180, height: 180)
                    Text(accessory.rawValue)
                }
            }
        }
        HStack {
            ForEach(AvatarMicroAction.allCases, id: \\.self) { action in
                VStack {
                    DinosaurAvatarRenderer(mood: .idle, tint: .purple, time: 1, reduceMotion: false, microAction: action).frame(width: 180, height: 180)
                    Text(action.rawValue)
                }
            }
        }
    }.padding(24).background(Color.white).foregroundStyle(.black)
    let renderer = ImageRenderer(content: sheet)
    renderer.scale = 2
    guard let image = renderer.nsImage, let data = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ContactSheet", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}
''')
manifest = dest / 'Package.swift'
s = manifest.read_text().replace('.target(name: "OsaurusCore"),', '.target(name: "OsaurusCore"), .executableTarget(name: "Render", dependencies: ["OsaurusCore"]),')
manifest.write_text(s)
render = dest / 'Sources/Render'
render.mkdir(exist_ok=True)
(render / 'main.swift').write_text('import OsaurusCore\ntry renderAvatarContactSheet(to: CommandLine.arguments[1])\n')
env = os.environ.copy()
env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="credential.helper", GIT_CONFIG_VALUE_0="",
           CLANG_MODULE_CACHE_PATH=str(root / "build/ModuleCache"), SWIFTPM_MODULECACHE_OVERRIDE=str(root / "build/ModuleCache"),
           OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS="1", OSAURUS_TEST_ROOT=str(root / "build/T09/test-root"), OSU_MODELS_DIR=str(root / "build/T09/test-models"))
for key in list(env):
    if key.startswith("OSAURUS_TALK_"): del env[key]
command = ["swift", "test", "--disable-keychain", "--disable-sandbox", "--build-system", "native",
           "--package-path", str(dest), "--cache-path", str(root / "build/swiftpm-cache"),
           "--config-path", str(root / "build/swiftpm-config"), "--security-path", str(root / "build/swiftpm-security"), "--jobs", "4"]
print("Running:", " ".join(command), flush=True)
with (root / "build/T09/isolated.log").open("w") as output:
    result = subprocess.run(command, cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
print("Tests exit:", result.returncode, flush=True)
if result.returncode == 0:
    with (root / 'build/T09/render.log').open('w') as output:
        result = subprocess.run([str(dest / '.build/debug/Render'), str(root / 'build/T09/contact-sheet.png')], cwd=root, env=env, stdout=output, stderr=subprocess.STDOUT)
    print("Render exit:", result.returncode)
raise SystemExit(result.returncode)
