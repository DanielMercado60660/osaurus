import AppKit
import Combine
import Foundation

@MainActor
final class TailscalePhoneAccessService: ObservableObject {
    static let shared = TailscalePhoneAccessService()
    @Published private(set) var state = PhoneAccessState()
    @Published private(set) var enabled: Bool
    @Published private(set) var allowedLogins: String
    @Published private(set) var restrictDevices: Bool
    @Published private(set) var allowedDeviceIDs: Set<String>
    @Published private(set) var devices: [PhoneAccessDevice]
    private let defaults: UserDefaults
    private let screen: @MainActor () -> PhoneScreenService
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var serverPort: Int?
    private var retiringProcesses: [Process] = []
    private var restartTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, screen: @escaping @MainActor () -> PhoneScreenService = { .shared }) {
        self.screen = screen
        self.defaults = defaults
        enabled = defaults.bool(forKey: "phoneAccess.enabled")
        allowedLogins = defaults.string(forKey: "phoneAccess.allowedLogins") ?? ""
        restrictDevices = defaults.bool(forKey: "phoneAccess.restrictDevices")
        allowedDeviceIDs = Set(defaults.stringArray(forKey: "phoneAccess.allowedDeviceIDs") ?? [])
        devices = defaults.data(forKey: "phoneAccess.devices")
            .flatMap { try? JSONDecoder().decode([PhoneAccessDevice].self, from: $0) } ?? []
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "phoneAccess.enabled")
        if value { startIfEnabled() } else {
            defaults.set(false, forKey: "phoneAccess.allowScreenViewing")
            defaults.removeObject(forKey: "phoneAccess.screenLastUsed")
            screen().setAllowed(false)
            stop()
        }
    }

    func saveAllowedLogins(_ value: String) {
        allowedLogins = value.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }.joined(separator: ",")
        defaults.set(allowedLogins, forKey: "phoneAccess.allowedLogins")
        stop(); startIfEnabled()
    }

    func saveDeviceRestrictions(_ restricted: Bool, selectedIDs: Set<String>) {
        restrictDevices = restricted
        allowedDeviceIDs = selectedIDs
        defaults.set(restricted, forKey: "phoneAccess.restrictDevices")
        defaults.set(selectedIDs.sorted(), forKey: "phoneAccess.allowedDeviceIDs")
        stop(); startIfEnabled()
    }

    // Keep discoveries across helper restarts so a denied phone can be selected.
    // Names are display-only; the helper authorizes the WhoIs StableID.
    func recordDevice(_ device: PhoneAccessDevice) {
        if let index = devices.firstIndex(where: { $0.stableID == device.stableID }) {
            guard devices[index] != device else { return }
            devices[index] = device
        } else { devices.append(device) }
        defaults.set(try? JSONEncoder().encode(devices), forKey: "phoneAccess.devices")
    }

    func serverStarted(port: Int) { serverPort = port; stop(); startIfEnabled() }
    func serverStopped() { serverPort = nil; stop() }

    func stop() {
        generation = UUID()
        restartTask?.cancel(); restartTask = nil
        PhoneAccessTrust.shared.replace(with: nil)
        screen().stopViewing()
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
            try PhoneAccessHelperIntegrity.validate(helper: helper)
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
                "OSAURUS_PHONE_UPSTREAM": "http://127.0.0.1:\(port)",
                "OSAURUS_PHONE_STATE": directory.path,
                "OSAURUS_PHONE_LOGINS": allowedLogins,
                "OSAURUS_PHONE_RESTRICT_DEVICES": restrictDevices ? "1" : "0",
                "OSAURUS_PHONE_DEVICES": allowedDeviceIDs.sorted().joined(separator: ","),
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
            // Check the path again immediately before Process resolves it.
            try PhoneAccessHelperIntegrity.validate(helper: helper)
            try child.run()
            try stdin.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
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
            if let event = PhoneAccessStatus.parse(line) {
                if let device = event.device { recordDevice(device) }
                else {
                    state.receive(event)
                    if event.type == "owner_login", let owner = event.value {
                        PhoneAccessTrust.shared.setOwnerLogin(owner)
                    }
                }
            }
        }
        if buffer.count > 16_384 { stop(); state.fail("Invalid oversized helper status.") }
    }
}
