import Foundation

/// Non-chat engines do not belong in ModelRuntime's eviction/ownership map.
/// Track their real owners weakly instead: stopping audio does not unload a
/// cached engine, and a worker retaining an engine keeps its charge alive.
/// This supplements the same RAM projection used by core-model/chat loads.
/// Do NOT subtract these resident estimates from measured host headroom: the
/// host sample already includes their physical pages.
final class AuxiliaryModelResidency: @unchecked Sendable {
    static let shared = AuxiliaryModelResidency()
    enum Kind: String, Codable, Sendable { case stt, tts, vad, privacy, smartTurn }
    struct Entry: Sendable {
        let kind: Kind
        let estimatedBytes: UInt64?
    }
    private struct Resident {
        weak var owner: AnyObject?
        let entry: Entry
    }
    private let lock = NSLock()
    private var residents: [ObjectIdentifier: Resident] = [:]

    func track(_ owner: AnyObject, kind: Kind, estimatedBytes: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        residents[ObjectIdentifier(owner)] = Resident(owner: owner,
            entry: Entry(kind: kind, estimatedBytes: estimatedBytes))
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        residents = residents.filter { $0.value.owner != nil }
        return residents.values.map(\.entry)
    }

    var knownEstimatedBytes: Int64 {
        Int64(min(UInt64(Int64.max), TalkMemoryBudget.sum(snapshot().compactMap(\.estimatedBytes))))
    }
}

/// Estimate, not physical footprint: logical bytes of the loaded artifacts ×
/// 1.25 for runtime state/activations. Same inflation as ordinary chat in
/// GPUMemoryBudget; no per-model size table. Missing/unreadable files stay
/// unknown. Call on a utility task, never recursively stat files in a UI body.
enum AuxiliaryModelEstimate {
    static func bytes(at roots: [URL]) -> UInt64? {
        guard !roots.isEmpty else { return nil }
        let fm = FileManager.default
        var total: UInt64 = 0
        var seen = Set<String>()
        func add(_ url: URL) throws {
            let resolved = url.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { return }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total = TalkMemoryBudget.sum([total, UInt64(max(0, size))])
            }
        }
        do {
            for root in roots {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    var failed = false
                    guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [], errorHandler: { _, _ in failed = true; return false }) else { return nil }
                    for case let url as URL in files { try add(url) }
                    if failed { return nil }
                } else { try add(root) }
            }
        } catch { return nil }
        guard total > 0, total <= UInt64(Int64.max) else { return nil }
        return GPUMemoryBudget.estimatedChatWorkingSetBytes(onDiskBytes: Int64(total))
    }
}
