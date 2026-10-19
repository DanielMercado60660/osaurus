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
    private var talkObserver: AnyCancellable?
    private var focusObserver: AnyCancellable?
    private var selectedAgentID: UUID?
    var isVisible: Bool { panel?.isVisible == true }
    var companionAgentID: UUID {
        if !TalkModeController.shared.isStopping, TalkModeController.shared.isActive, let id = TalkModeController.shared.agentID { return id }
        let manager = ChatWindowManager.shared
        return selectedAgentID
            ?? manager.lastFocusedWindowId.flatMap { manager.windowState(id: $0)?.activeAgent.id }
            ?? AgentManager.shared.activeAgentId
    }
    private var preferenceObserver: AnyCancellable?

    private override init() { super.init() }

    func start() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyPreference() }
        let talk = TalkModeController.shared
        talkObserver = Publishers.CombineLatest3(talk.$state, talk.$isStarting, talk.$isStopping)
            .receive(on: RunLoop.main)
            .sink { [weak self] state, starting, stopping in
                self?.resize(presence: state != .off || starting || stopping)
            }
        focusObserver = ChatWindowManager.shared.$lastFocusedWindowId
            .sink { [weak self] _ in self?.selectedAgentID = nil }
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
        panel.toggleTalk = { [weak self] in self?.toggleTalk() }
        panel.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        let host = NSHostingController(
            rootView:
                LiveAgentAvatarView(followsFocusedChat: true)
                .padding(10)
                .help("Click to talk. Drag to move. Right-click for chat and agents.")
                .accessibilityLabel("Talk to companion")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { [weak self] in self?.toggleTalk() }
                .accessibilityAction(named: "Open chat") { [weak self] in self?.openChat() }
                .accessibilityAction(named: "Hide companion") { [weak self] in self?.hideCompanion() }
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
        resize(presence: TalkModeController.shared.isActive, animated: false)
        panel.orderFront(nil)
    }

    func hide() {
        TalkModeController.shared.dismissCompanion()
        panel?.saveFrame(usingName: "AnimatedAgentAvatar")
        panel?.orderOut(nil)
        // Destroy the host as well: no hidden timeline or sampling task survives.
        panel?.contentViewController = nil
        panel = nil
    }

    func windowDidMove(_ notification: Notification) {
        panel?.saveFrame(usingName: "AnimatedAgentAvatar")
    }

    func toggleTalk() {
        let id = companionAgentID
        let talk = TalkModeController.shared
        talk.toggle(agentID: id, withoutWindow: true)
        if !talk.isActive, talk.lastError != nil {
            talk.avatarEvents.send((id, .reaction(.oops)))
        }
    }

    private func resize(presence: Bool, animated: Bool = true) {
        guard let panel else { return }
        let size = presence ? NSSize(width: 280, height: 390) : NSSize(width: 180, height: 190)
        guard panel.frame.size != size else { return }
        var frame = NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.minY, width: size.width, height: size.height)
        if let screen = panel.screen ?? NSScreen.main {
            let bounds = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - size.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - size.height)
        }
        panel.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    @objc private func hideCompanion() {
        UserDefaults.standard.set(false, forKey: AnimatedAvatarSetting.defaultsKey)
        hide()
    }

    @objc private func chooseAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        TalkModeController.shared.dismissCompanion()
        TalkModeController.shared.stop()
        selectedAgentID = id
        AgentManager.shared.setActiveAgent(id)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Open chat", #selector(openChat)), ("Hide companion", #selector(hideCompanion))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for agent in AgentManager.shared.agents {
            let item = NSMenuItem(title: agent.name, action: #selector(chooseAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.state = agent.id == companionAgentID ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openChat() {
        let manager = ChatWindowManager.shared
        let id = companionAgentID
        if let window = TalkModeController.shared.windowID,
           manager.windowState(id: window)?.activeAgent.id == id {
            manager.showWindow(id: window)
        } else if let window = manager.findWindows(byAgentId: id).first {
            manager.showWindow(id: window.id)
        } else {
            manager.createWindow(agentId: id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Intercept only this panel's pointer events, retaining native window dragging.
private final class AvatarPanel: NSPanel {
    var toggleTalk: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    private var downPoint: NSPoint?
    private var downEvent: NSEvent?
    private var dragged = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            if let menu = makeMenu?(), let view = contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
            return
        case .leftMouseDown:
            if event.modifierFlags.contains(.control) {
                if let menu = makeMenu?(), let view = contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
                return
            }
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
            if downPoint != nil && !dragged { toggleTalk?() }
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
