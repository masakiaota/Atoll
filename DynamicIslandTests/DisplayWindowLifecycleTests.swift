import AppKit

// Only unrelated services are fixtures. The runner inserts the production
// AppDelegate methods and dictionaries, and compiles the real window class.
@MainActor
enum Defaults {
    enum BoolKey { case showOnAllDisplays, automaticallySwitchDisplay }
    enum HideKey { case hideNotchOption }
    enum HideOption { case never }
    static var showOnAllDisplays = true
    static subscript(_ key: BoolKey) -> Bool {
        key == .showOnAllDisplays ? showOnAllDisplays : true
    }
    static subscript(_ key: HideKey) -> HideOption { .never }
}

@MainActor
final class DynamicIslandViewModel {
    enum State { case closed, open }
    var screen: String?
    var notchState = State.closed
    var notchSize = CGSize(width: 690, height: 498)
    var isMenuBarExpanded = false
    var onViewTeardown: (() -> Void)?
    var destroyed = false
    init(screen: String? = nil) { self.screen = screen }
    func close() { notchState = .closed }
    func destroy() { destroyed = true }
}

@MainActor
final class FocusTaskManager {
    static let shared = FocusTaskManager()
    var hasActiveTask = true
}

@MainActor
final class ScreenCaptureVisibilityManager {
    static let shared = ScreenCaptureVisibilityManager()
    enum Scope { case entireInterface }
    func register(_ window: NSWindow, scope: Scope) {}
    func unregister(_ window: NSWindow) {}
}

@MainActor
final class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    final class Space { var windows: Set<NSWindow> = [] }
    let notchSpace = Space()
}

func getClosedNotchSize(screen: String?) -> CGSize { CGSize(width: 690, height: 498) }

@MainActor
final class AppDelegate: NSObject {
    final class Coordinator {
        var preferredScreen = "Test display"
        var selectedScreen = "Test display"
    }
    let coordinator = Coordinator()
    let vm = DynamicIslandViewModel()
    var window: NSWindow?
    var windowsHiddenForLock = false

    func adjustedSizeForScreen(_ size: CGSize, screen: NSScreen) -> CGSize { size }

    func createDynamicIslandWindow(for screen: NSScreen, with viewModel: DynamicIslandViewModel) -> NSWindow {
        let window = DynamicIslandWindow(
            contentRect: CGRect(x: 0, y: 0, width: 690, height: 498),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        window.contentView = NSView()
        // The actual panel is shown for native lifecycle assertions, but draws
        // no pixels and never becomes key or moves the user's pointer.
        window.backgroundColor = .clear
        return window
    }

    // APP_DELEGATE_METHODS
}

@MainActor
final class TestScreen: NSScreen {
    let id: CGDirectDisplayID
    let rectangle: CGRect
    init(id: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.rectangle = frame
        super.init()
    }
    override var frame: NSRect { rectangle }
    override var visibleFrame: NSRect { rectangle }
    override var localizedName: String { "Test display" }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    override var backingScaleFactor: CGFloat { 2 }
    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): NSNumber(value: id)]
    }
    override var hash: Int { Int(id) }
    override func isEqual(_ object: Any?) -> Bool { (object as? TestScreen)?.id == id }
}

@MainActor
enum ScreenSource {
    static var current: [NSScreen] = []
}

@main
@MainActor
private struct DisplayWindowLifecycleTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // The runner substitutes only AppDelegate's screen source, leaving
        // AppKit's own screens and the user's display configuration untouched.
        testCurrentGeometryAndDisplayIdentity()
        testRestorationAfterRemoval()
        testRestorationAfterModeChange()
        testRestorationAfterTaskEndsOrScreenLocks()
        print("DisplayWindowLifecycleTests passed (4 scenarios)")
    }

    static func screen(_ id: CGDirectDisplayID = 2, _ frame: CGRect = CGRect(x: 0, y: 0, width: 2560, height: 1080)) -> NSScreen {
        TestScreen(id: id, frame: frame)
    }

    static func drainMainQueue() {
        var finished = false
        DispatchQueue.main.async { finished = true }
        while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    }

    static func testCurrentGeometryAndDisplayIdentity() {
        Defaults.showOnAllDisplays = true
        ScreenSource.current = [screen(2, CGRect(x: 2560, y: 0, width: 2560, height: 1080))]
        let delegate = AppDelegate()
        delegate.adjustWindowPosition()
        let window = delegate.windows.values.first!
        precondition(window.frame.origin == CGPoint(x: 3495, y: 582))

        ScreenSource.current = [screen(2, CGRect(x: 608, y: 1593, width: 2560, height: 1080))]
        delegate.screenConfigurationDidChange()
        drainMainQueue()
        delegate.resizeWindows(to: CGSize(width: 690, height: 498), animated: false, force: true)
        precondition(delegate.windows.count == 1 && delegate.windows.values.first === window,
                     "A rearranged display must reuse its window")
        precondition(window.frame.origin == CGPoint(x: 1543, y: 2175),
                     "Resizing after rearrangement must use current geometry, not the old dictionary key")

        // A resolution change must also affect clamping and centering.
        ScreenSource.current = [screen(2, CGRect(x: -400, y: 50, width: 500, height: 400))]
        delegate.resizeWindows(to: CGSize(width: 690, height: 498), animated: false, force: true)
        precondition(window.frame == ScreenSource.current[0].frame)

        // Identical names and rectangles must not hide a change in display ID.
        let previousModel = delegate.viewModels.values.first!
        ScreenSource.current = [screen(3, ScreenSource.current[0].frame)]
        delegate.screenConfigurationDidChange()
        drainMainQueue()
        precondition(delegate.windows.count == 1 && delegate.windows.values.first !== window)
        precondition(!window.isVisible && window.contentView == nil && previousModel.destroyed)
        delegate.closeAllDisplayWindows()
    }

    static func testRestorationAfterRemoval() {
        Defaults.showOnAllDisplays = true
        let delegate = AppDelegate()
        for id in CGDirectDisplayID(10)..<20 {
            ScreenSource.current = [screen(id)]
            delegate.adjustWindowPosition()
            let retired = delegate.windows.values.first!
            delegate.restoreFocusTaskWindowsAfterTransition()
            ScreenSource.current = [screen(id + 1)]
            delegate.adjustWindowPosition()
            drainMainQueue()
            precondition(!retired.isVisible && retired.contentView == nil,
                         "Queued restoration must never reopen a retired panel")
            let visible = NSApplication.shared.windows.filter { $0 is DynamicIslandWindow && $0.isVisible }
            precondition(visible.count == 1 && visible.first === delegate.windows.values.first,
                         "Repeated display replacement must leave exactly the currently owned panel visible")
        }
        delegate.closeAllDisplayWindows()
    }

    static func testRestorationAfterModeChange() {
        Defaults.showOnAllDisplays = true
        ScreenSource.current = [screen()]
        let delegate = AppDelegate()
        delegate.adjustWindowPosition()
        let allDisplaysPanel = delegate.windows.values.first!
        delegate.restoreFocusTaskWindowsAfterTransition()
        Defaults.showOnAllDisplays = false
        delegate.reconcileWindowsForDisplayMode()
        let singlePanel = delegate.window!
        drainMainQueue()
        precondition(!allDisplaysPanel.isVisible && singlePanel.isVisible)

        delegate.restoreFocusTaskWindowsAfterTransition()
        Defaults.showOnAllDisplays = true
        delegate.reconcileWindowsForDisplayMode()
        drainMainQueue()
        precondition(!singlePanel.isVisible && delegate.windows.values.first!.isVisible)
        delegate.closeAllDisplayWindows()
    }

    static func testRestorationAfterTaskEndsOrScreenLocks() {
        Defaults.showOnAllDisplays = true
        ScreenSource.current = [screen()]
        let delegate = AppDelegate()
        delegate.adjustWindowPosition()
        let window = delegate.windows.values.first!
        window.orderOut(nil)
        delegate.restoreFocusTaskWindowsAfterTransition()
        FocusTaskManager.shared.hasActiveTask = false
        drainMainQueue()
        precondition(!window.isVisible)

        FocusTaskManager.shared.hasActiveTask = true
        delegate.restoreFocusTaskWindowsAfterTransition()
        delegate.windowsHiddenForLock = true
        drainMainQueue()
        precondition(!window.isVisible)
        delegate.closeAllDisplayWindows()
    }
}
