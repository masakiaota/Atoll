import AppKit
import ApplicationServices
import Combine

/// Observes the overflow button, not ordinary NSMenu tracking. macOS 27 keeps
/// several menu-bar trees (including inactive Spaces) alive at the same location.
@MainActor
final class MenuBarOverflowMonitor: ObservableObject {
    static let shared = MenuBarOverflowMonitor()
    @Published private(set) var expandedScreens: Set<String> = []
    @Published private(set) var availableLeftWidths: [String: CGFloat] = [:]

    private let reader = MenuBarOverflowReader()
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []

    private init() {
        guard !AppRuntimeEnvironment.isUITesting else { return }
        reader.didChange = { [weak self] expanded, widths in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.expandedScreens != expanded { self.expandedScreens = expanded }
                if self.availableLeftWidths != widths { self.availableLeftWidths = widths }
            }
        }
        reader.requestRefresh = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(rediscover: true) }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(rediscover: true) } })
        // Recovery for missed notifications, permission changes, and menu-bar auto-hide.
        // AX IPC runs on a serial worker, never on the UI thread.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh(rediscover: true)
    }

    private func refresh(rediscover: Bool = false) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.compactMap { screen -> MenuBarOverflowReader.Display? in
            guard let notch = screen.physicalNotchFrame else { return nil }
            return .init(name: screen.localizedName,
                         frame: CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                                       width: screen.frame.width, height: notch.height),
                         notchMinX: notch.minX)
        }
        reader.refresh(screens: screens,
                       frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                       rediscover: rediscover)
    }
}

private final class MenuBarOverflowReader: @unchecked Sendable {
    struct Display: Sendable {
        let name: String
        let frame: CGRect // AX / Core Graphics coordinates
        let notchMinX: CGFloat
    }
    var didChange: (@Sendable (Set<String>, [String: CGFloat]) -> Void)?
    var requestRefresh: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "dev.atoll.menu-bar-overflow", qos: .userInteractive)
    private var observer: AXObserver?
    private var pid: pid_t = 0
    private var buttons: [AXUIElement] = []
    private var lastDiscovery = Date.distantPast
    private var lastExpanded: Set<String> = []
    private let labels: (show: Set<String>, hide: Set<String>) = {
        var show: Set<String> = ["Show Hidden Menu Bar Items", "非表示のメニューバー項目を表示"]
        var hide: Set<String> = ["Hide Menu Bar Items", "メニューバー項目を非表示"]
        // Read all translations, since the host app's language can differ from macOS.
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
        if let data = try? Data(contentsOf: url),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for translations in table.values {
                guard let strings = translations as? [String: String] else { continue }
                if let value = strings["menuBar.showOverflowItemsAccessibilityLabel"] { show.insert(value) }
                if let value = strings["menuBar.hideOverflowItemsAccessibilityLabel"] { hide.insert(value) }
            }
        }
        return (show, hide)
    }()

    func refresh(screens: [Display], frontPID: pid_t?, rediscover: Bool) {
        queue.async { [self] in
            guard AXIsProcessTrusted(), !screens.isEmpty else {
                disconnect()
                didChange?([], [:])
                return
            }
            let currentPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
                .first?.processIdentifier ?? 0
            guard currentPID != 0 else {
                disconnect()
                didChange?([], [:])
                return
            }
            let reconnect = pid != currentPID || observer == nil
            if reconnect { connect(pid: currentPID) }
            if reconnect || rediscover || buttons.isEmpty || Date().timeIntervalSince(lastDiscovery) > 5 {
                discoverButtons()
            }
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.1)
            var expanded = lastExpanded.intersection(Set(screens.map(\.name)))
            var candidateScreens: Set<String> = []
            var sampledPositions: Set<String> = []
            for candidate in buttons {
                guard let rect = frame(candidate), rect.width > 0, rect.height > 0,
                      let screen = screens.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) else { continue }
                candidateScreens.insert(screen.name)
                let key = "\(rect.midX),\(rect.midY)"
                guard sampledPositions.insert(key).inserted else { continue }
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(system, Float(rect.midX), Float(rect.midY), &hit) == .success,
                      let hit, elementPID(hit) == pid,
                      string(hit, kAXRoleAttribute) == kAXButtonRole else { continue }
                // Use the actual hit element. Never combine the states of inactive menu bars.
                if let description = string(hit, kAXDescriptionAttribute) {
                    if labels.hide.contains(description) { expanded.insert(screen.name) }
                    if labels.show.contains(description) { expanded.remove(screen.name) }
                }
            }
            expanded.formIntersection(candidateScreens)
            let widths = availableWidths(screens: screens, frontPID: frontPID)
            lastExpanded = expanded
            didChange?(expanded, widths)
        }
    }

    private func connect(pid newPID: pid_t) {
        disconnect()
        pid = newPID
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let owner = Unmanaged<MenuBarOverflowReader>.fromOpaque(context).takeUnretainedValue()
            // Keep the callback short: even reads may block in another application.
            var elementPID: pid_t = 0
            AXUIElementGetPid(element, &elementPID)
            owner.queue.async {
                guard elementPID == owner.pid else { return }
                owner.requestRefresh?()
            }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success, let newObserver else { return }
        observer = newObserver
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.1)
        // Only observe app-level structural changes here. Button value notifications
        // are registered directly, avoiding the clock and foreign embedded app trees.
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(newObserver, root, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func disconnect() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        buttons = []
        lastExpanded = []
        pid = 0
    }

    private func discoverButtons() {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.1)
        var found: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= 3, elementPID(element) == pid else { return }
            if string(element, kAXRoleAttribute) == kAXButtonRole,
               let description = string(element, kAXDescriptionAttribute),
               labels.show.contains(description) || labels.hide.contains(description) {
                if !found.contains(where: { CFEqual($0, element) }) { found.append(element) }
                return
            }
            for child in children(element) { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        if let observer {
            for old in buttons where !found.contains(where: { CFEqual($0, old) }) {
                AXObserverRemoveNotification(observer, old, kAXValueChangedNotification as CFString)
            }
            for element in found where !buttons.contains(where: { CFEqual($0, element) }) {
                AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
        }
        buttons = found
        lastDiscovery = Date()
    }

    private func availableWidths(screens: [Display], frontPID: pid_t?) -> [String: CGFloat] {
        guard let frontPID else { return [:] }
        let app = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let barValue = attribute(app, kAXMenuBarAttribute), CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return [:] }
        let bar = unsafeBitCast(barValue, to: AXUIElement.self)
        let frames = children(bar).compactMap(frame)
        return Dictionary(uniqueKeysWithValues: screens.map { screen in
            let menuRight = frames.filter { $0.intersects(screen.frame) && $0.minX < screen.notchMinX }
                .map(\.maxX).max() ?? screen.frame.minX
            return (screen.name, max(0, screen.notchMinX - menuRight - 12))
        })
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ key: String) -> String? { attribute(element, key) as? String }
    private func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func elementPID(_ element: AXUIElement) -> pid_t { var value: pid_t = 0; AXUIElementGetPid(element, &value); return value }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
