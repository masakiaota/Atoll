import AppKit

/// Tells the notch windows when Mission Control is showing.
///
/// macOS 27 announces Mission Control through no notification, AX event or
/// AppKit callback. It does, however, hide every `.transient` window for its
/// duration, and AppKit reports that as an occlusion change. So an invisible
/// 1pt transient window acts as the sensor, which lets the notch itself be
/// `.stationary`: unmoved by "Show Desktop", and hidden here during Mission
/// Control instead of by the system.
@MainActor
final class MissionControlProbe {
    static let shared = MissionControlProbe()

    /// True once the sensor has been seen on screen, i.e. it can be trusted.
    private(set) var isReliable = false
    private(set) var isMissionControlActive = false

    private var window: NSPanel?
    private var tokens: [NSObjectProtocol] = []
    private var recheck: Timer?

    private init() {}

    func start() {
        guard !AppRuntimeEnvironment.isUITesting, window == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .transient]
        panel.animationBehavior = .none
        window = panel
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
        place()
    }

    private func place() {
        guard let window, let screen = NSScreen.screens.first else { return }
        // The top-left pixel of the primary display: under the Apple menu, never covered by a normal window.
        window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.maxY - 1))
        window.orderFrontRegardless()
        evaluate()
    }

    private func evaluate() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        if visible { isReliable = true }
        // Before the sensor has ever been visible, its absence means nothing.
        let active = isReliable && !visible
        debugLog("occlusion visible=\(visible) reliable=\(isReliable) active=\(active)")
        recheck?.invalidate()
        recheck = nil
        if active {
            // If the sensor is lost for another reason (display sleep, a
            // rearranged display), bring it back so the notch cannot stay hidden.
            recheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    if !window.isVisible || window.screen == nil { self.place() }
                }
            }
        }
        isMissionControlActive = active
        for notch in DynamicIslandWindow.allWindows { notch.applyMissionControlState() }
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: "menuBarCollisionDebugLog") else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Atoll-mission-control.log")
        let line = "\(Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true))) \(message())\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        } else { try? Data(line.utf8).write(to: url) }
    }
}
