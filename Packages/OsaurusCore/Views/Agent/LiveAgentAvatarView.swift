import AppKit
import SwiftUI

/// Resolves sources at the surface boundary, leaving the renderer reusable in
/// previews and a future 3D host. Window occlusion also pauses the sampler.
struct LiveAgentAvatarView: View {
    var agentID: UUID? = nil
    var mascotID: String? = nil
    var followsFocusedChat = false
    @StateObject private var model = AvatarStateModel()
    @State private var visible = false
    @State private var windowID: UUID?

    var body: some View {
        AnimatedAgentAvatarView(
            mood: model.mood,
            tint: (mascotID ?? model.agent.avatar).flatMap(AgentMascot.init(rawValue:))?.color
                ?? AgentMascot.blue.color,
            isVisible: visible
        )
        .background(
            AvatarWindowVisibility { isVisible, window in
                visible = isVisible
                windowID = window.flatMap { ChatWindowManager.shared.windowId(for: $0) }
            }
        )
        .onDisappear { visible = false }
        .task(id: visible) {
            guard visible else { return }
            var last = ContinuousClock.now
            while !Task.isCancelled {
                let now = ContinuousClock.now
                let duration = last.duration(to: now).components
                let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                model.sample(agentID: agentID, windowID: followsFocusedChat ? nil : windowID, elapsed: elapsed)
                last = now
                do {
                    try await Task.sleep(for: .seconds(model.mood.isSpeaking ? 1.0 / 30 : 0.1))
                } catch { return }
            }
        }
    }
}

/// onDisappear alone does not fire when an NSPanel is ordered out or a chat
/// is minimized. Observe its actual window, never global mouse events.
struct AvatarWindowVisibility: NSViewRepresentable {
    var changed: (Bool, NSWindow?) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = changed
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    final class VisibilityView: NSView {
        var changed: ((Bool, NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [
                    NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                ] {
                    NotificationCenter.default.addObserver(
                        self,
                        selector: #selector(refresh),
                        name: name,
                        object: window
                    )
                }
            }
            refresh()
        }

        @objc private func refresh() {
            // Defer out of the AppKit/SwiftUI view update transaction.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible =
                    window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
                changed?(visible, window)
            }
        }
    }
}
