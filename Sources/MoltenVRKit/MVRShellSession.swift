import AppKit
import SwiftUI
import IOSurface

/// Your app's connection to the MoltenVR shell. Create one session, `start()` it, and
/// present SwiftUI views as panels that appear inside the user's headset:
///
///     let session = MVRShellSession(appName: "My App")
///     session.start()
///     session.presentPanel(id: "main", title: "My App",
///                          pointSize: CGSize(width: 620, height: 420),
///                          placement: MVRPanelPlacement(x: 0.6, y: 1.6, z: -1.4)) {
///         MyPanelView()
///     }
///
/// The session keeps retrying while MoltenVR isn't running and re-registers every panel
/// after each reconnect, so start order doesn't matter. Text fields in your panels bring up
/// MoltenVR's VR keyboard, and typed text arrives as ordinary key input.
@MainActor
public final class MVRShellSession: ObservableObject {
    @Published public private(set) var state: MVRSessionState = .disconnected
    /// Whether the shell overlay is currently open in the headset. Panels stay registered
    /// either way; the idle shell (no game running) also shows panels.
    @Published public private(set) var shellOpen = false
    public var onEvent: ((MVRShellEvent) -> Void)?

    private let connection: KitConnection
    private var panels: [UInt32: MVRPanel] = [:]
    private var nextWireId: UInt32 = 1
    private var started = false
    private var screenObserver: NSObjectProtocol?
    private var toastPanel: MVRPanel?
    private var toastDismissTask: Task<Void, Never>?

    /// `icon` appears next to your app's name in MoltenVR's dock (128px is plenty).
    /// Omitted, it falls back to your app's own icon.
    public init(appName: String, icon: NSImage? = nil) {
        connection = KitConnection(appName: appName)
        self.icon = icon ?? NSApp.applicationIconImage
        wireCallbacks()
    }

    /// Change the dock icon (re-sent on every reconnect).
    public var icon: NSImage? {
        didSet { if state == .connected { sendIcon() } }
    }

    private func sendIcon() {
        guard let icon else { return }
        // the dock shows it at about 34pt and the wire caps it at 256KB
        let side: CGFloat = 128
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count <= 256 * 1024 else { return }
        connection.send(.appIcon, png)
    }

    public func start() {
        guard !started else { return }
        started = true
        state = .connecting
        connection.start()
        // panel windows hide just off the primary screen, so a display change can expose them
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for host in self.panels.values.compactMap(\.host) {
                    host.window.replaceHidden()
                    host.stopCapture()
                    if self.state == .connected { host.startCapture() }
                }
            }
        }
    }

    public func stop() {
        started = false
        connection.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastPanel = nil
        for p in panels.values { p.host?.tearDown() }
        panels.removeAll()
        state = .disconnected
    }

    /// Show a popup notification in the headset. A new toast replaces the current one and
    /// restarts its dismissal timer. The toast uses one panel slot while it is visible.
    public func showToast(_ message: String, duration: Duration = .seconds(3)) {
        let panel: MVRPanel
        if let existing = toastPanel, existing.isPresented {
            panel = existing
            panel.setContent { MVRToastView(message: message) }
        } else {
            panel = presentPanel(
                id: "__moltenvrkit.toast",
                title: "Notification",
                pointSize: CGSize(width: 600, height: 150),
                placement: MVRPanelPlacement(y: 1.7, z: -1.2, widthMeters: 0.9,
                                             zOrder: 100)
            ) {
                MVRToastView(message: message)
            }
            toastPanel = panel
        }

        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, let panel,
                  self.toastPanel === panel else { return }
            self.dismissToast()
        }
    }

    /// Dismiss the currently visible toast, if any.
    public func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastPanel?.remove()
        toastPanel = nil
    }

    /// Present a SwiftUI view as a VR shell panel. `pointSize` is the panel's layout size
    /// in points (rendered at 2x); its aspect fixes the panel's height in meters.
    @discardableResult
    public func presentPanel<V: View>(id: String, title: String,
                                      pointSize: CGSize,
                                      placement: MVRPanelPlacement,
                                      @ViewBuilder content: () -> V) -> MVRPanel {
        let host = PanelHost(pointSize: pointSize,
                             content: AnyView(content()))
        let wireId = allocWireId()
        let panel = MVRPanel(id: id, title: title, placement: placement, wireId: wireId,
                             host: host, surfaceId: { host.surfacePublisher.surfaceId },
                             contentAspect: Float(pointSize.height / pointSize.width),
                             session: self)
        host.onTextFocusChanged = { [weak self, weak panel] active in
            guard let self, let panel else { return }
            self.connection.send(.textFocus,
                                 KitWire.encodePair(panel.wireId, active ? 1 : 0))
        }
        host.onCaptureBlocked = { [weak self] in
            self?.onEvent?(.panelBlocked(id: id))
        }
        panels[wireId] = panel
        if state == .connected {
            upsert(panel)
            host.startCapture()
        }
        return panel
    }

    /// For Metal and game apps: present a global IOSurface you render yourself. No
    /// ScreenCaptureKit and no permission; pointer events arrive raw on `onPointer`. Create
    /// the surface with IOSurfaceIsGlobal. To resize, make a new surface and call
    /// `update(placement:)`.
    @discardableResult
    public func presentSurfacePanel(id: String, title: String,
                                    surface: IOSurfaceRef,
                                    placement: MVRPanelPlacement,
                                    onPointer: ((MVRPointerEvent) -> Void)? = nil) -> MVRPanel {
        let wireId = allocWireId()
        let sid = IOSurfaceGetID(surface)
        let aspect = Float(IOSurfaceGetHeight(surface)) / Float(max(1, IOSurfaceGetWidth(surface)))
        let panel = MVRPanel(id: id, title: title, placement: placement, wireId: wireId,
                             host: nil, surfaceId: { sid }, contentAspect: aspect,
                             session: self)
        panel.onPointer = onPointer
        panels[wireId] = panel
        if state == .connected { upsert(panel) }
        return panel
    }

    private func allocWireId() -> UInt32 {
        defer { nextWireId += 1 }
        return nextWireId
    }

    func upsert(_ panel: MVRPanel) {
        let p = panel.placement
        connection.send(.panelUpsert, KitWire.encode(KitWire.PanelDesc(
            panelId: panel.wireId,
            surfaceId: panel.surfaceId(),
            pos: (p.x, p.y, p.z),
            quat: p.quat,
            size: (p.widthMeters, p.widthMeters * panel.contentAspect),
            curvature: p.curvature,
            opacity: p.opacity,
            z: p.zOrder,
            flags: 0b11,   // visible, hit-testable
            title: panel.title)))
    }

    func removePanel(_ panel: MVRPanel) {
        panels.removeValue(forKey: panel.wireId)
        panel.host?.tearDown()
        connection.send(.panelRemove, KitWire.encodeU32(panel.wireId))
    }

    private func wireCallbacks() {
        connection.onConnected = { [weak self] ack in
            guard let self else { return }
            state = .connected
            shellOpen = ack.shellOpen
            onEvent?(.connected)
            // the broker forgets us on disconnect
            sendIcon()
            for panel in panels.values {
                upsert(panel)
                panel.host?.startCapture()
            }
        }
        connection.onDisconnected = { [weak self] in
            guard let self else { return }
            state = self.started ? .connecting : .disconnected
            shellOpen = false
            for p in panels.values { p.host?.stopCapture() }
            onEvent?(.disconnected)
        }
        connection.onShellState = { [weak self] open in
            guard let self else { return }
            shellOpen = open
            onEvent?(open ? .shellOpened : .shellClosed)
        }
        connection.onPointer = { [weak self] ev in
            guard let self, let panel = panels[ev.panelId] else { return }
            let mv = MVRPointerEvent(hand: Int(ev.hand), u: ev.u, v: ev.v,
                                     buttons: ev.buttons,
                                     scrollX: ev.scrollX, scrollY: ev.scrollY)
            if ev.u < 0 {
                panel.host?.pointerLeft()
            } else {
                panel.host?.handlePointer(mv)
            }
            panel.onPointer?(mv)
        }
        connection.onPanelMoved = { [weak self] mv in
            self?.panels[mv.panelId]?.adoptMove(mv)
        }
        connection.onText = { [weak self] panelId, text in
            self?.panels[panelId]?.host?.insertText(text)
        }
        connection.onKey = { [weak self] key in
            self?.panels[key.panelId]?.host?.sendKey(key)
        }
        connection.onRejected = { [weak self] panelId, reason in
            guard let self, let panel = panels[panelId] else { return }
            onEvent?(.panelRejected(id: panel.id,
                                    reason: MVRRejectReason(rawValue: reason) ?? .unknown))
        }
    }
}
