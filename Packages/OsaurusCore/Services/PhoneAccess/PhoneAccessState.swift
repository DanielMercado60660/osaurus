import Foundation

struct PhoneAccessDevice: Codable, Equatable, Sendable, Identifiable {
    let stableID: String
    let name: String
    let login: String
    let allowed: Bool
    var id: String { stableID }
}

struct PhoneAccessStatus: Decodable, Equatable, Sendable {
    let type: String
    let value: String?
    var device: PhoneAccessDevice? = nil

    static func parse(_ line: String) -> Self? {
        guard line.utf8.count <= 16_384,
            let data = line.data(using: .utf8),
            let status = try? JSONDecoder().decode(Self.self, from: data),
            ["login_url", "running", "dns_name", "owner_login", "error", "device"].contains(status.type)
        else { return nil }
        if status.type == "device" {
            guard let device = status.device, !device.stableID.isEmpty,
                device.stableID.utf8.count <= 256, !device.stableID.contains(","),
                !device.name.isEmpty
            else { return nil }
            return status
        }
        guard let value = status.value, !value.isEmpty else { return nil }
        if status.type == "login_url" || status.type == "running" {
            guard let url = URL(string: value), let host = url.host, !host.isEmpty,
                url.user == nil, url.password == nil,
                (url.scheme == "https" || (status.type == "running" && url.scheme == "http"))
            else { return nil }
        }
        return status
    }
}

struct PhoneAccessState: Equatable, Sendable {
    enum Phase: String, Sendable { case stopped, starting, needsLogin, running, failed }
    var phase: Phase = .stopped
    var loginURL: URL?
    var phoneURL: URL?
    var dnsName: String?
    var ownerLogin: String?
    var error: String?

    mutating func start() { self = Self(); phase = .starting }
    mutating func stop() { self = Self() }
    mutating func fail(_ message: String) { self = Self(); phase = .failed; error = message }
    mutating func receive(_ event: PhoneAccessStatus) {
        guard phase != .stopped && phase != .failed else { return }
        switch event.type {
        case "login_url":
            guard phase != .running else { return }
            phase = .needsLogin; loginURL = event.value.flatMap(URL.init(string:))
        case "running":
            phase = .running; phoneURL = event.value.flatMap(URL.init(string:)); loginURL = nil
        case "dns_name": dnsName = event.value
        case "owner_login": ownerLogin = event.value
        case "error": fail(event.value ?? "Helper failed")
        default: break
        }
    }
}

/// The launch capability is memory-only, rotated on restart, and never sent to
/// the browser. Marked proxy requests must not inherit ordinary loopback trust.
final class PhoneAccessTrust: @unchecked Sendable {
    static let shared = PhoneAccessTrust()
    static let secretHeader = "X-Osaurus-Phone-Secret"
    static let deviceHeader = "X-Osaurus-Phone-Device"
    static let originHeader = "X-Osaurus-Phone-Origin"
    private let lock = NSLock()
    private var secret: String?

    func replace(with value: String?) { lock.lock(); defer { lock.unlock() }; secret = value }
    func accepts(_ candidate: String?, physicalLoopback: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard physicalLoopback, let secret, let candidate, secret.utf8.count >= 32 else { return false }
        let a = Array(secret.utf8), b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
