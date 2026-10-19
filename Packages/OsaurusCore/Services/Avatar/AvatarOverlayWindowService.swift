import AppKit
import Combine
import SwiftUI

/// UI-only preference, shared by Settings, empty chat heroes and launch restore.
enum AnimatedAvatarSetting {
    static let defaultsKey = "showAnimatedAgentAvatar"
}

@MainActor
final class AvatarOverlayWindowService: NSObject, NSWindowDelegate {
    static let shared = AvatarOverlayWindowService()
    private var panel: AvatarPanel?
    private var preferenceObserver: AnyCancellable?

    private override init() { super.init() }

    func start() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPreference() }
        applyPreference()
    }

    func applyPreference() {
        if UserDefaults.standard.bool(forKey: AnimatedAvatarSetting.defaultsKey) { show() } else { hide() }
    }

    func show() {
        guard panel == nil else { return }
        let panel = AvatarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.openChat = { [weak self] in self?.openChat() }
        let host = NSHostingController(
            rootView:
                LiveAgentAvatarView(followsFocusedChat: true)
                .padding(10)
                .help("Drag to move. Click to open the agent's chat.")
                .accessibilityLabel("Open agent chat")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { [weak self] in self?.openChat() }
        )
        // The panel handles click versus drag so a drag never opens a chat.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentViewController = host
        if !panel.setFrameUsingName("AnimatedAgentAvatar") {
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 210, y: screen.visibleFrame.minY + 30))
            }
        }
        // A disconnected display must not strand the persisted panel offscreen.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(panel.frame) }), let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 210, y: screen.visibleFrame.minY + 30))
        }
        panel.setFrameAutosaveName("AnimatedAgentAvatar")
        self.panel = panel
        panel.orderFront(nil)
    }

    func hide() {
        panel?.saveFrame(usingName: "AnimatedAgentAvatar")
        panel?.orderOut(nil)
        // Destroy the host as well: no hidden timeline or sampling task survives.
        panel?.contentViewController = nil
        panel = nil
    }

    func windowDidMove(_ notification: Notification) {
        panel?.saveFrame(usingName: "AnimatedAgentAvatar")
    }

    private func openChat() {
        let manager = ChatWindowManager.shared
        if let id = manager.lastFocusedWindowId, manager.windowState(id: id) != nil {
            manager.showWindow(id: id)
        } else {
            manager.createWindow(agentId: AgentManager.shared.activeAgentId)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Intercept only this panel's pointer events, retaining native window dragging.
private final class AvatarPanel: NSPanel {
    var openChat: (() -> Void)?
    private var downPoint: NSPoint?
    private var downEvent: NSEvent?
    private var dragged = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downPoint = NSEvent.mouseLocation
            downEvent = event
            dragged = false
        case .leftMouseDragged:
            if let downPoint, hypot(NSEvent.mouseLocation.x - downPoint.x, NSEvent.mouseLocation.y - downPoint.y) > 3 {
                dragged = true
                performDrag(with: downEvent ?? event)
                self.downPoint = nil
                downEvent = nil
                return
            }
        case .leftMouseUp:
            if downPoint != nil && !dragged { openChat?() }
            downPoint = nil
            downEvent = nil
        default: break
        }
        // Don't let the hosting view start an independent background drag.
        if event.type != .leftMouseDown && event.type != .leftMouseDragged && event.type != .leftMouseUp {
            super.sendEvent(event)
        }
    }
}
