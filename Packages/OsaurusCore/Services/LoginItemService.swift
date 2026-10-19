//
//  LoginItemService.swift
//  osaurus
//
//  Created by Terence on 8/31/25.
//

import Foundation
import Combine
import ServiceManagement

/// Manages "Start at Login" registration for the main app
@MainActor
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()
    private init() {}

    /// Returns whether the app is currently registered to start at login
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @Published private(set) var statusMessage = "Start at Login: checking…"
    private var generalPreference = false
    private var phoneRequired = false
    private var update: Task<Void, Never>?
    private var revision = 0

    func setPhoneAccessRequired(_ enabled: Bool, generalPreference: Bool? = nil) {
        if let generalPreference { self.generalPreference = generalPreference }
        guard phoneRequired != enabled else { return }
        phoneRequired = enabled
        applyStartAtLogin(self.generalPreference)
    }

    /// Phone access requires login registration independently of the General
    /// preference. Serial operations prevent rapid toggles from racing XPC.
    func applyStartAtLogin(_ enabled: Bool) {
        generalPreference = enabled
        let required = PhoneReachabilityPolicy.requiresLogin(generalPreference: enabled, phoneEnabled: phoneRequired)
        revision += 1
        let current = revision, previous = update
        statusMessage = "Start at Login: updating…"
        update = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            let service = SMAppService.mainApp
            let message: String
            do {
                if required {
                    if service.status != .enabled { try service.register() }
                } else if service.status != .notRegistered {
                    try await service.unregister()
                }
                switch service.status {
                case .enabled: message = "Start at Login: enabled"
                case .requiresApproval: message = "Start at Login needs approval in System Settings → General → Login Items."
                case .notRegistered: message = "Start at Login: off"
                default: message = "Start at Login unavailable. Install a signed app in Applications and try again."
                }
            } catch {
                let error = error as NSError
                message = "Start at Login failed (\(error.domain) \(error.code)): \(error.localizedDescription). Unsigned/development builds may not register; install a signed app in Applications and check System Settings → General → Login Items."
            }
            await self?.finish(message, revision: current)
        }
    }

    private func finish(_ message: String, revision: Int) {
        guard revision == self.revision else { return }
        statusMessage = message
    }
}
