import AppKit
import Carbon
import SwiftUI

enum SearchShortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionO, disabled
    static let preferenceKey = "searchShortcut"
    var id: String { rawValue }
    var label: String {
        switch self { case .optionSpace: return "Option–Space"; case .controlOptionO: return "Control–Option–O"; case .disabled: return "Off" }
    }
    var keyCode: UInt32 { self == .controlOptionO ? UInt32(kVK_ANSI_O) : UInt32(kVK_Space) }
    var modifiers: UInt32 { self == .controlOptionO ? UInt32(controlKey | optionKey) : UInt32(optionKey) }
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .optionSpace
    }
}

/// Owns the search surface and its system-wide shortcut. Carbon hot keys do not
/// require Input Monitoring or Accessibility access, and report key conflicts.
@MainActor final class SpotlightPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var shortcutError: String?
    @Published private(set) var shortcut = SearchShortcut.saved()
    private let drive: Drive
    private var panel: SpotlightPanel?
    private var indexWindow: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private let hotKeyID = EventHotKeyID(signature: 0x43445352, id: 1) // CDSR

    init(drive: Drive) {
        self.drive = drive
        super.init()
    }

    /// Called once at launch; idempotent so registration can be retried.
    func registerShortcut() {
        guard hotKey == nil, shortcut != .disabled else { return }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x43445352, identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let controller = Unmanaged<SpotlightPanelController>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in controller.toggle() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else {
                shortcutError = "\(shortcut.label) could not be registered. Search is still available from the CloudDrive menu."
                return
            }
        }
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        shortcutError = status == noErr ? nil : "\(shortcut.label) is unavailable. Another app may be using it. Search is still available from the CloudDrive menu."
    }

    func changeShortcut(_ value: SearchShortcut) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        shortcut = value; shortcutError = nil
        UserDefaults.standard.set(value.rawValue, forKey: SearchShortcut.preferenceKey)
        registerShortcut()
    }

    func toggle() {
        if panel?.isVisible == true { dismiss() } else { show() }
    }

    func show() {
        if panel?.isVisible == true {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: SpotlightSearchView(drive: drive, catalog: drive.catalog, onDismiss: { [weak self] in
            self?.dismiss()
        }, onOpenIndex: { [weak self] in self?.showIndex() }))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let frame = screen.visibleFrame
            let size = NSSize(width: min(720, frame.width), height: min(560, frame.height))
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - min(120, frame.height * 0.12), width: size.width, height: size.height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        installMouseMonitors()
    }

    func showIndex() {
        dismiss()
        if indexWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Search Drive"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SearchView(drive: drive, catalog: drive.catalog))
            window.center()
            indexWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        indexWindow?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        panel?.contentView = nil // Cancel search tasks and release focus with the surface.
        removeMouseMonitors()
        // A nonactivating panel leaves the previous app active. AppKit restores
        // its key focus; explicitly activating it here would steal focus back
        // from a file that has just been opened in another application.
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click elsewhere can transfer the key window before the mouse monitor.
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        panel?.contentView = nil
        removeMouseMonitors()
    }

    private func makePanel() -> SpotlightPanel {
        let panel = SpotlightPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI supplies a shadow around the actual glass shape.
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Search CloudDrive")
        panel.onCancel = { [weak self] in self?.dismiss() }
        return panel
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window !== panel { self.dismiss() }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }
}

private final class SpotlightPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
