import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PhoneAccessSettingsCard: View {
    @ObservedObject private var service = TailscalePhoneAccessService.shared
    @EnvironmentObject var server: ServerController
    @State private var logins = ""

    var body: some View {
        GroupBox("Phone access over Tailscale") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Phone access",
                    isOn: Binding(
                        get: { service.enabled },
                        set: { enabled in
                            service.setEnabled(enabled)
                            if enabled && !server.isRunning { Task { await server.startServer() } }
                        }
                    )
                )
                .settingsLandingAnchor("server.phoneAccess")
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
                    "Comma-separated logins. Empty uses the login that owns this node. Allowed logins have owner access to this Mac's agents."
                ).font(.caption)
                if let owner = service.state.ownerLogin { Text("Effective logins: \(owner)").font(.caption) }
                Button("Save allowed logins") {
                    service.saveAllowedLogins(logins); logins = service.allowedLogins
                }
                .settingsLandingAnchor("server.phoneAccess.saveLogins")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { logins = service.allowedLogins }
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
