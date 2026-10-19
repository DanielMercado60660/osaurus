#!/usr/bin/env python3
"""Prepare dependency-free T08 checks under build/T08-mac-control/isolated.

Copies real source and tests; extracts the act/verification methods and scene
schema verbatim. Only the unrelated activity-feed sink and localization UI
helper are stubbed. This is not the full app, loop runner, or evals lane.
Use --without-settle for an expected-failing negative control in the COPY.
"""
import sys
import json
from pathlib import Path
import shutil
root = Path(__file__).resolve().parents[2]
out = root / 'build/T08-mac-control/isolated'
core = out / 'Sources/OsaurusCore'
evals = out / 'Sources/OsaurusEvalsKit'
tests = out / 'Tests/T08Tests'
for d in [core, evals, tests]: d.mkdir(parents=True, exist_ok=True)
def read(p): return (root / p).read_text()
def section(s, a, b): return s[s.index(a):s.index(b, s.index(a))]
def copy(p, d): shutil.copyfile(root/p, d/Path(p).name)
prefix = 'Packages/OsaurusCore/'
for p in ['ComputerUse/Driver/AppCatalog.swift', 'ComputerUse/Driver/MacDriver.swift',
          'ComputerUse/Model/AgentAction.swift', 'ComputerUse/Model/AgentView.swift',
          'ComputerUse/Policy/EffectClass.swift', 'ComputerUse/Telemetry/ComputerUseRunMetrics.swift',
          'Tools/SchemaValidator.swift']:
    copy(prefix+p, core)
api = read(prefix+'Models/API/OpenAIAPI.swift')
(core/'API.swift').write_text('import Foundation\n'+section(api, 'struct Tool: Codable', 'extension ToolFunction {'))
s = read(prefix+'ComputerUse/Driver/Mac/BackgroundDriver.swift')
(core/'InputRoute.swift').write_text('import Foundation\n'+section(s, 'public enum InputRoute:', '// MARK: - App Class Detection'))
s = read(prefix+'Tools/OsaurusTool.swift')
(core/'ArgumentCoercion.swift').write_text('import Foundation\n'+s[s.index('public enum ArgumentCoercion {'):])
s = read(prefix+'ComputerUse/Loop/ComputerUseLoop.swift')
(core/'ComputerUseLoopAct.swift').write_text('import Foundation\npublic enum ComputerUseLoop {\n'
    + 'static let scrollAmountRange: ClosedRange<Int> = 1 ... 1000\n'
    + section(s, '    static func act(', '    // MARK: - Model step') + '\n}\n'
    + s[s.index('extension Comparable {'):])
s = read(prefix+'ComputerUse/Perception/CaptureRouter.swift')
(core/'CaptureRouter.swift').write_text('import Foundation\n'
    + section(s, 'public enum EscalationReason:', '/// Where a perceived frame')
    + section(s, 'public enum CaptureRouter', '    /// Whether the cloud-vision route') + '\n}\n')
s = read(prefix+'Subagent/SubagentFeed.swift')
(core/'FeedStub.swift').write_text('import Foundation\n'
    + section(s, 'public struct SubagentActivityEvent:', '// MARK: - Status')
    + '''public final class SubagentFeed: @unchecked Sendable {
public init(toolCallId: String, kindId: String, title: String) {}
public func emit(_ event: SubagentActivityEvent) {}
}
''')
s = read('Packages/OsaurusEvals/Sources/OsaurusEvalsKit/EvalCase.swift')
(evals/'Scene.swift').write_text('import Foundation\npublic struct EvalCase {\n'
    + section(s, '    public struct ComputerUseLoopExpectations:', '    /// Expectation for `domain == "subagent"`') + '\n}\n')
copy('Packages/OsaurusEvals/Sources/OsaurusEvalsKit/ScriptedCUDriver.swift', evals)
for p in ['Packages/OsaurusCore/Tests/ComputerUse/Driver/AppCatalogTests.swift',
          'Packages/OsaurusCore/Tests/ComputerUse/Model/AgentActionDecodeTests.swift',
          'Packages/OsaurusEvals/Tests/OsaurusEvalsKitTests/DelayedTextDeliveryTests.swift']:
    copy(p, tests)
(out/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "T08Checks", platforms: [.macOS(.v14)], targets: [
.target(name: "OsaurusCore"),
.target(name: "OsaurusEvalsKit", dependencies: ["OsaurusCore"]),
.testTarget(name: "T08Tests", dependencies: ["OsaurusCore", "OsaurusEvalsKit"])
])
''')
(core/'LocalizationStub.swift').write_text('func L(_ text: String) -> String { text }\n')
if '--without-settle' in sys.argv:
    p = core / 'ComputerUseLoopAct.swift'
    s = p.read_text()
    original = 'guard result.success, isTextMutation(action) else { return snapshot }'
    assert s.count(original) == 1
    p.write_text(s.replace(original, 'guard false else { return snapshot }', 1))
(root/'build/T08-mac-control/main.swift').write_text('import Foundation\nlet url = URL(fileURLWithPath: "/System/Applications/Notes.app")\nif let entry = CUAppCatalogEntry.read(at: url, preferredLanguages: ["ru-RU", "de-DE", "ja-JP"]) {\n    for name in ["заметки", "ЗАМЕТКИ", "NOTIZEN", "メモ", "COM.APPLE.NOTES", "Notes"] {\n        let match = CUAppResolver.resolve(name, in: [entry])\n        print("\\(name): \\(match?.url.path ?? "NOT FOUND")")\n        precondition(match?.url == url)\n    }\n} else { fatalError("Notes bundle unavailable") }\n')
suite = root / 'Packages/OsaurusEvals/Suites/ComputerUseLoop'
cases = [json.loads(p.read_text()) for p in suite.glob('*.json')]
new = json.loads((suite/'delayed-text-delivery.json').read_text())
for action in new['expect']['computerUseLoop']['scriptedActions']:
    assert isinstance(json.loads(action), dict)
print(f"Parsed {len(cases)} scene JSON files and both new scripted actions.")
print(out)
