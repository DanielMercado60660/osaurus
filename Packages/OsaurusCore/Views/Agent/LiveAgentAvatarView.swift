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
    @State private var hostWindow: NSWindow?
    @ObservedObject private var talk = TalkModeController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presence: Bool { followsFocusedChat && talk.isActive }
    private var status: String {
        if talk.isStarting { return "Getting ready…" }
        if talk.isStopping { return "Stopping…" }
        switch talk.state {
        case .off: return "Ready"
        case .listening, .userSpeaking, .endOfTurn: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }
    private var mascot: String? { mascotID ?? model.agent.avatar }

    var body: some View {
        VStack(spacing: 4) {
            if presence && talk.configuration.showCaptions {
                Text(model.assistantCaption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .opacity(model.assistantCaption.isEmpty ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: model.assistantCaption.isEmpty)
                    .lineLimit(4)
                    .frame(height: model.assistantCaption.isEmpty ? 0 : 90)
                    .accessibilityLabel("Assistant: \(model.assistantCaption)")
            }
            AnimatedAgentAvatarView(
                mood: model.mood,
                tint: mascot.flatMap(AgentMascot.init(rawValue:))?.color ?? AgentMascot.blue.color,
                isVisible: visible,
                reaction: model.reaction,
                microAction: reduceMotion ? nil : model.microAction,
                accessory: AvatarAccessory.mascot(mascot),
                gaze: reduceMotion ? .zero : model.gaze
            )
            if presence {
                Text(talk.configuration.showCaptions && model.mood.isListening && !talk.caption.isEmpty
                     ? talk.caption : status)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(height: 40)
            }
        }
        .background(
            AvatarWindowVisibility { isVisible, window in
                visible = isVisible
                hostWindow = window
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
                model.sample(
                    agentID: followsFocusedChat ? AvatarOverlayWindowService.shared.companionAgentID : agentID,
                    windowID: followsFocusedChat ? nil : windowID, elapsed: elapsed,
                    mouseOrigin: hostWindow.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
                )
                last = now
                do {
                    try await Task.sleep(for: .seconds(model.mood.frameInterval))
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
