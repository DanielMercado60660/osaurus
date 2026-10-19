import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class TailscalePhoneAccessService: ObservableObject {
    static let shared = TailscalePhoneAccessService()
    @Published private(set) var state = PhoneAccessState()
    @Published private(set) var enabled: Bool
    @Published private(set) var allowedLogins: String
    private let defaults: UserDefaults
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var serverPort: Int?
    private var retiringProcesses: [Process] = []
    private var restartTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "phoneAccess.enabled")
        allowedLogins = defaults.string(forKey: "phoneAccess.allowedLogins") ?? ""
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "phoneAccess.enabled")
        if value { startIfEnabled() } else { stop() }
    }

    func saveAllowedLogins(_ value: String) {
        allowedLogins = value.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }.joined(separator: ",")
        defaults.set(allowedLogins, forKey: "phoneAccess.allowedLogins")
        stop(); startIfEnabled()
    }

    func serverStarted(port: Int) { serverPort = port; stop(); startIfEnabled() }
    func serverStopped() { serverPort = nil; stop() }

    func stop() {
        generation = UUID()
        restartTask?.cancel(); restartTask = nil
        PhoneAccessTrust.shared.replace(with: nil)
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let child = process, child.isRunning {
            retiringProcesses.append(child)
            child.terminate()
            // Escalate only this retained Process if graceful shutdown wedges.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil; input = nil; output = nil; buffer.removeAll()
        state.stop()
    }

    func startIfEnabled() {
        guard enabled, process == nil else { return }
        guard let port = serverPort else { state.fail("Start the local server to enable Phone access."); return }
        state.start()
        // A previous tsnet instance must release its persistent node state
        // before a new one starts (allowlist saves and server port changes).
        retiringProcesses.removeAll { !$0.isRunning }
        if !retiringProcesses.isEmpty {
            let current = generation
            restartTask?.cancel()
            restartTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.startIfEnabled()
            }
            return
        }
        restartTask = nil
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/osaurus-ts")
            let pinURL = helper.appendingPathExtension("sha256")
            let pin = try String(contentsOf: pinURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let digest = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
            guard pin.count == 64, digest == pin,
                FileManager.default.isExecutableFile(atPath: helper.path)
            else { throw PhoneAccessLaunchError.unverifiedHelper }
            let directory = OsaurusPaths.root().appendingPathComponent("phone-access", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let token = UUID().uuidString + UUID().uuidString
            PhoneAccessTrust.shared.replace(with: token)
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = helper
            // Deliberately do not inherit TS_AUTHKEY or other ambient Tailscale configuration.
            child.environment = [
                "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                "OSAURUS_PHONE_SECRET": token,
                "OSAURUS_PHONE_UPSTREAM": "http://127.0.0.1:\(port)",
                "OSAURUS_PHONE_STATE": directory.path,
                "OSAURUS_PHONE_LOGINS": allowedLogins,
            ]
            child.standardInput = stdin; child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            let current = generation
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.consume(bytes)
                }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    let message =
                        self.state.error
                        ?? "Phone helper exited (\(child.terminationStatus)). Turn Phone access off and on to retry."
                    self.stop(); self.state.fail(message)
                }
            }
            process = child; input = stdin; output = stdout
            try child.run()
        } catch {
            stop()
            state.fail(
                "Phone helper could not start: \(error.localizedDescription). Build and embed it with make app (Go required)."
            )
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<end], as: UTF8.self)
            buffer.removeSubrange(...end)
            if let event = PhoneAccessStatus.parse(line) { state.receive(event) }
        }
        if buffer.count > 16_384 { stop(); state.fail("Invalid oversized helper status.") }
    }
}

private enum PhoneAccessLaunchError: LocalizedError {
    case unverifiedHelper
    var errorDescription: String? { "Bundled osaurus-ts digest does not match its build pin" }
}
