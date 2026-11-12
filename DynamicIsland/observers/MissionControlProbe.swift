import AppKit

/// Tells the notch windows when Mission Control is showing.
///
/// macOS 27 announces Mission Control through no notification, AX event, KVO
/// or AppKit callback. It does, however, hide every `.transient` window for its
/// duration, and AppKit reports that as an occlusion change. So an invisible
/// 1pt transient window acts as the sensor, which lets the notch itself be
/// `.stationary`: unmoved by "Show Desktop" and by Space swipes, and hidden
/// here during Mission Control instead of by the system.
///
/// A Space swipe hides the sensor as well, so the change is confirmed against
/// Dock's full-display overlay, which only Mission Control puts up. Nothing
/// runs between these transitions. The occlusion change arrives roughly a
/// quarter of a second after Mission Control appears; no earlier signal exists.
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

    private var sensorHiddenAt: TimeInterval = 0
    private var generation = 0

    private func evaluate() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        if visible { isReliable = true }
        generation += 1
        recheck?.invalidate()
        recheck = nil
        guard isReliable, !visible else {
            debugLog("sensor visible -> show")
            setActive(false)
            return
        }
        // A Space swipe hides the sensor too, but only Mission Control puts
        // Dock's overlay across the display. Look for it now and for a moment
        // after; nothing runs outside these transitions.
        sensorHiddenAt = ProcessInfo.processInfo.systemUptime
        let token = generation
        for delay in [0.0, 0.03, 0.06, 0.1, 0.15, 0.25, 0.4, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token, !self.isMissionControlActive else { return }
                    let overlays = self.dockWindows()
                    self.debugLog("sensor hidden +\(Int(delay * 1000))ms dock=\(overlays)")
                    if overlays.contains(where: { $0.layer >= 18 && $0.width >= 600 && $0.height >= 400 }) {
                        self.setActive(true)
                    }
                }
            }
        }
        // If the sensor is lost for another reason (display sleep, a
        // rearranged display), bring it back.
        recheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                if !window.isVisible || window.screen == nil { self.place() }
            }
        }
    }

    private func setActive(_ active: Bool) {
        if active != isMissionControlActive {
            isMissionControlActive = active
            debugLog("mission control active=\(active)")
        }
        for notch in DynamicIslandWindow.allWindows { notch.applyMissionControlState() }
        AppDelegate.shared?.setTuckedForMissionControl(isReliable && isMissionControlActive)
    }

    private struct DockWindow: CustomStringConvertible {
        let layer: Int, width: CGFloat, height: CGFloat
        var description: String { "L\(layer):\(Int(width))x\(Int(height))" }
    }
    private lazy var dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    private func dockWindows() -> [DockWindow] {
        if let pid = dockPID, NSRunningApplication(processIdentifier: pid) == nil { dockPID = nil }
        if dockPID == nil {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        }
        guard let dockPID else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == dockPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat else { return nil }
            return DockWindow(layer: info[kCGWindowLayer as String] as? Int ?? 0, width: width, height: height)
        }
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
