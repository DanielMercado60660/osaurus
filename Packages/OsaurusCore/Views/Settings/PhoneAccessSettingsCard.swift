import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PhoneAccessSettingsCard: View {
    @ObservedObject private var service = TailscalePhoneAccessService.shared
    @ObservedObject private var reachability = PhoneReachabilityService.shared
    @ObservedObject private var login = LoginItemService.shared
    @ObservedObject private var screen = PhoneScreenService.shared
    @State private var screenPermission = false
    @EnvironmentObject var server: ServerController
    @State private var logins = ""
    @State private var restrictDevices = false
    @State private var selectedIDs: Set<String> = []

    var body: some View {
        GroupBox("Phone access over Tailscale") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Keep my AI reachable",
                    isOn: Binding(
                        get: { service.enabled },
                        set: { enabled in
                            service.setEnabled(enabled)
                            if enabled && !server.isRunning { Task { await server.startServer() } }
                        }
                    )
                )
                .settingsLandingAnchor("server.phoneAccess")
                Text(PhoneReachabilityPolicy.status(enabled: service.enabled, power: reachability.power,
                    assertionActive: reachability.assertionActive, state: service.state))
                    .font(.caption).textSelection(.enabled)
                if service.enabled {
                    Text(login.statusMessage).font(.caption).textSelection(.enabled)
                    if let error = reachability.assertionError { Text(error).foregroundStyle(.red) }
                }
                Text("Starts at login in the menu bar and prevents idle system sleep on AC power. The display may sleep. Battery power, closing the lid, manual sleep, shutdown, or quitting Osaurus can make your Mac unreachable.")
                    .font(.caption)
                Toggle("Allow phone to view this Mac's screen", isOn: Binding(
                    get: { screen.allowed }, set: { screen.setAllowed($0) }
                ))
                .settingsLandingAnchor("server.phoneAccess.screen")
                .disabled(!service.enabled)
                Text("Only devices signed in as this tailnet node’s owner can view the screen. Other allowed logins can chat. Turns off with Phone access or after 7 days unused.").font(.caption)
                if let expires = screen.expiresAt, screen.allowed {
                    Text("Screen access expires if unused: \(expires.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
                Text("Screen Recording: \(screenPermission ? "Granted" : "Not granted")")
                    .font(.caption)
                Button("Open Screen Recording Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .settingsLandingAnchor("server.phoneAccess.screenPermission")
                Text("The phone Screen panel shows the main display. A floating overlay and menu-bar indicator appear while viewing; each session posts a notification. Actions use a Computer Use agent and its existing approvals; keep a Mac chat window open for approval cards.")
                    .font(.caption)
                Text("Status: \(service.state.phase.rawValue)")
                if let error = service.state.error { Text(error).foregroundStyle(.red) }
                if let url = service.state.loginURL {
                    Link("Sign in to Tailscale", destination: url)
                        .settingsLandingAnchor("server.phoneAccess.login")
                    qr(url)
                }
                if let url = service.state.phoneURL {
                    Text(url.absoluteString).textSelection(.enabled)
                    qr(url)
                    if url.scheme == "http" {
                        Text(
                            "Tailnet HTTPS certificates are unavailable. Text chat works over the encrypted tailnet; microphone and PWA installation require HTTPS."
                        )
                        .font(.caption)
                    }
                }
                TextField("Allowed Tailscale logins", text: $logins)
                    .settingsLandingAnchor("server.phoneAccess.logins")
                Text(
                    "Comma-separated logins. Empty uses the login that owns this node. Every device signed in to an allowed login has owner access to this Mac's agents unless you restrict devices below. We recommend a tailnet ACL to limit which devices can reach this node."
                ).font(.caption)
                if let owner = service.state.ownerLogin { Text("Tailnet node owner: \(owner)").font(.caption) }
                Button("Save allowed logins") {
                    service.saveAllowedLogins(logins); logins = service.allowedLogins
                }
                .settingsLandingAnchor("server.phoneAccess.saveLogins")
                Toggle("Restrict access to selected devices", isOn: $restrictDevices)
                    .settingsLandingAnchor("server.phoneAccess.restrictDevices")
                Text("Connected devices").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    if service.devices.isEmpty {
                        Text("Open the phone URL on a tailnet device to list it here, even if access is denied.")
                            .font(.caption)
                    }
                    ForEach(service.devices) { device in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(device.stableID) },
                            set: { selected in
                                if selected { selectedIDs.insert(device.stableID) }
                                else { selectedIDs.remove(device.stableID) }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text("\(device.login.isEmpty ? "Unknown login" : device.login) · \(device.stableID)").font(.caption).textSelection(.enabled)
                                Text("Last request: \(device.allowed ? "allowed" : "denied")").font(.caption)
                            }
                        }
                        .disabled(!restrictDevices)
                    }
                }
                .settingsLandingAnchor("server.phoneAccess.devices")
                Text("With restrictions on, selecting no devices denies all access. Device selection never bypasses the login allowlist. Changes apply when saved.")
                    .font(.caption)
                Button("Save device restrictions") {
                    service.saveDeviceRestrictions(restrictDevices, selectedIDs: selectedIDs)
                }
                .settingsLandingAnchor("server.phoneAccess.saveDevices")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screen.refreshAvailability()
            screenPermission = SystemScreenshotPermissionChecker().hasScreenRecordingPermission()
        }
        .onAppear {
            screen.refreshAvailability()
            screenPermission = SystemScreenshotPermissionChecker().hasScreenRecordingPermission()
            logins = service.allowedLogins
            restrictDevices = service.restrictDevices
            selectedIDs = service.allowedDeviceIDs
        }
    }

    @ViewBuilder private func qr(_ url: URL) -> some View {
        if let image = qrImage(url.absoluteString) {
            Image(nsImage: image).interpolation(.none).resizable().frame(width: 180, height: 180)
                .padding(8).background(.white).accessibilityLabel("QR code for \(url.absoluteString)")
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
