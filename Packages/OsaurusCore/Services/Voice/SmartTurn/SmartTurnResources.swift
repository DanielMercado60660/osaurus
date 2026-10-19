import Foundation
import Combine

/// Reuse external HF snapshots read-only. Downloads live in Osaurus aux-models,
/// never in the chat picker and never remove or rewrite the owner's HF cache.
enum SmartTurnResources {
    static let repository = "mlx-community/smart-turn-v3"
    static let revision = "74af1538ebace37b0fcc667a6a8a3d902d73eee0"
    static let modelBytes: Int64 = 32_010_016
    static var ownedDirectory: URL {
        OsaurusPaths.root().appendingPathComponent("aux-models/smart-turn-v3/\(revision)")
    }
    static func availableDirectory() -> URL? {
        locate(owned: ownedDirectory, home: FileManager.default.homeDirectoryForCurrentUser,
               environment: ProcessInfo.processInfo.environment)
    }
    static func locate(owned: URL, home: URL, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        func complete(_ url: URL) -> Bool {
            ["config.json", "model.safetensors"].allSatisfy {
                let path = url.appendingPathComponent($0)
                return (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } == true
            }
        }
        let hfHome = environment["HF_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".cache/huggingface")
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) } ?? hfHome.appendingPathComponent("hub")
        let repo = hub.appendingPathComponent("models--mlx-community--smart-turn-v3")
        var candidates: [URL] = []
        if let ref = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           ref.count == 40, ref.allSatisfy(\.isHexDigit) {
            candidates.append(repo.appendingPathComponent("snapshots/\(ref)"))
        }
        let snapshots = (try? fm.contentsOfDirectory(at: repo.appendingPathComponent("snapshots"),
            includingPropertiesForKeys: nil)) ?? []
        candidates += snapshots.sorted { $0.path < $1.path }
        candidates.append(owned)
        return candidates.first(where: complete)
    }
}

@MainActor
final class SmartTurnDownload: ObservableObject {
    static let shared = SmartTurnDownload()
    @Published private(set) var available = SmartTurnResources.availableDirectory() != nil
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var downloader: DirectDownloader?
    private var downloadID: UUID?

    func refresh() { available = SmartTurnResources.availableDirectory() != nil }
    func start() {
        guard task == nil else { return }
        refresh()
        guard !available else { return }
        error = nil; progress = 0
        let id = UUID()
        downloadID = id
        task = Task { [self] in
            let transfer = DirectDownloader()
            downloader = transfer
            defer { transfer.invalidate(); downloader = nil; task = nil; downloadID = nil; progress = nil }
            do {
                // Pin both files to the inspected conversion. DirectDownloader is
                // the same proxy-aware, verified transfer path used by ModelDownloadService.
                for (file, bytes) in [("model.safetensors", SmartTurnResources.modelBytes), ("config.json", Int64(351))] {
                    try Task.checkCancellation()
                    let url = URL(string: "https://huggingface.co/\(SmartTurnResources.repository)/resolve/\(SmartTurnResources.revision)/\(file)")!
                    try await transfer.download(from: url, to: SmartTurnResources.ownedDirectory.appendingPathComponent(file),
                        expectedSize: bytes, onProgress: { [weak self] received, total in
                            guard file == "model.safetensors" else { return }
                            Task { @MainActor in
                                guard let self, self.downloadID == id else { return }
                                self.progress = Double(received) / Double(max(1, total))
                            }
                        })
                }
                refresh()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { task?.cancel(); downloader?.invalidate() }
}
