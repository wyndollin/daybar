import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The status item and its hover panel, same behaviour as LimitBar: hover opens after 150 ms, leaving
/// closes after 250 ms, a click pins it open. A non-activating panel, so it never steals focus from the
/// app you're in — but it can take keyboard input for the quick-add field, which also pins it open.
/// ⌥Space opens it pinned with the field focused.
@MainActor
final class AppDelegate: NSResponder, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var tray: PassThroughHostingView<TrayView>!
    private var panel: KeyPanel!
    private var panelHost: NSHostingView<AnyView>!
    private let store = Store()
    private lazy var composer = Composer(store: store)
    private var subs = Set<AnyCancellable>()
    private var pinned = false
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var outsideClick: Any?
    private var keyMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var overItem = false
    private var overPanel = false

    override init() { super.init() }
    required init?(coder: NSCoder) { fatalError("not used") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        tray = PassThroughHostingView(rootView: TrayView(store: store))
        tray.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(tray)
        NSLayoutConstraint.activate([tray.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                                     tray.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        button.target = self
        button.action = #selector(clicked)
        button.setAccessibilityLabel("Today's events")
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: ["zone": "item"]))
        resizeItem()
        Publishers.Merge4(store.$events.map { _ in () }, store.$reminders.map { _ in () },
                          store.$now.map { _ in () }, store.$access.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.resizeItem(); self?.resizePanel() } }
            .store(in: &subs)
        // The composer grows/shrinks the panel, and pins it open while you're using it.
        composer.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.resizePanel()
                    if self.composer.isActive && self.panel.isVisible && !self.pinned { self.pin() }
                }
            }
            .store(in: &subs)
        buildPanel()
        installKeyMonitor()
        registerHotKey()
    }

    private func resizeItem() {
        tray.layoutSubtreeIfNeeded()
        item.length = ceil(tray.fittingSize.width)
    }

    // MARK: panel

    private func buildPanel() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                         styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 16
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        // The layer's corner radius doesn't clip the behind-window blur; without this mask its square
        // corners show past the rounded edge (visible over white backgrounds).
        fx.maskImage = Self.roundedMask(radius: 16)

        panelHost = NSHostingView(rootView: AnyView(PanelView(store: store, composer: composer, onQuit: { NSApp.terminate(nil) })))
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(panelHost)
        NSLayoutConstraint.activate([panelHost.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                                     panelHost.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     panelHost.topAnchor.constraint(equalTo: fx.topAnchor),
                                     panelHost.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        panel.contentView = fx
        fx.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: ["zone": "panel"]))
    }

    private func resizePanel() {
        guard panel != nil else { return }
        panelHost.layoutSubtreeIfNeeded()
        let size = panelHost.fittingSize
        guard size.height > 0, let button = item.button, let win = button.window else { return }
        let r = win.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = (win.screen ?? NSScreen.main)?.visibleFrame else { return }
        var x = r.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = r.minY - size.height - 5
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: panel.isVisible)
        panel.invalidateShadow()   // so the shadow follows the rounded shape, not the square window
    }

    /// A stretchable rounded-rect mask (Apple's way to round an NSVisualEffectView).
    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private func show() {
        guard !panel.isVisible else { return }
        store.reload()
        resizePanel()
        panel.orderFrontRegardless()
        item.button?.highlight(true)
    }

    private func hide() {
        guard !pinned else { return }
        panel.makeFirstResponder(nil)
        composer.fieldFocused = false
        panel.orderOut(nil)
        item.button?.highlight(false)
        composer.panelClosed()
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
    }

    /// Keep the panel open until a click elsewhere, the status item, or esc.
    private func pin() {
        pinned = true
        item.button?.highlight(true)
        guard outsideClick == nil else { return }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        pinned = false
        hide()
    }

    @objc private func clicked() {
        showTimer?.invalidate()
        if pinned {
            close()
        } else {
            show()
            pin()
        }
    }

    /// ⌥Space: open pinned with the field focused, or close if it's already open.
    fileprivate func hotKeyPressed() {
        if panel.isVisible && pinned { close(); return }
        showTimer?.invalidate(); hideTimer?.invalidate()
        show()
        pin()
        panel.makeKey()
        composer.focus()
    }

    // MARK: keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, e.window === self.panel else { return e }
                let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // An accessory app has no Edit menu, so the usual shortcuts need routing by hand.
                if mods.contains(.command) {
                    let sel: Selector? = switch e.charactersIgnoringModifiers?.lowercased() {
                    case "v": #selector(NSText.paste(_:))
                    case "c": #selector(NSText.copy(_:))
                    case "x": #selector(NSText.cut(_:))
                    case "a": #selector(NSText.selectAll(_:))
                    case "z": mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
                    default: nil
                    }
                    if let sel, NSApp.sendAction(sel, to: nil, from: self) { return nil }
                    return e
                }
                if self.composer.handle(keyCode: e.keyCode) { return nil }
                if e.keyCode == 53 { self.close(); return nil }   // esc on an empty field closes the panel
                return e
            }
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.hotKeyPressed() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: OSType(0x4459_4252), id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: hover

    override func mouseEntered(with event: NSEvent) {
        let zone = (event.trackingArea?.userInfo?["zone"] as? String) ?? ""
        if zone == "item" { overItem = true } else { overPanel = true }
        hideTimer?.invalidate()
        if zone == "item" && !panel.isVisible {
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.show() }
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        let zone = (event.trackingArea?.userInfo?["zone"] as? String) ?? ""
        if zone == "item" { overItem = false; showTimer?.invalidate() } else { overPanel = false }
        guard !pinned else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, !self.overItem, !self.overPanel else { return }
                self.hide()
            }
        }
    }
}

/// A borderless panel can't become key by default; this one can, so the text field takes typing —
/// still non-activating, so the app you were in stays frontmost.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The tray's SwiftUI view must not swallow clicks meant for the status bar button underneath it.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
