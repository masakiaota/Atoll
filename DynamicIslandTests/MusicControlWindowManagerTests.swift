import AppKit
import SwiftUI

// Replace unrelated app services while compiling the actual window manager.
@MainActor
final class SkyLightOperator {
    static let shared = SkyLightOperator()
    func delegateWindow(_ window: NSWindow) {}
}

@MainActor
final class ScreenCaptureVisibilityManager {
    static let shared = ScreenCaptureVisibilityManager()
    enum Scope { case entireInterface }
    weak var window: NSWindow?
    func register(_ window: NSWindow, scope: Scope) { self.window = window }
}

@MainActor
final class DynamicIslandViewModel {
    var screen = NSScreen.screens.first?.localizedName
    let effectiveClosedNotchHeight: CGFloat = 32
    let closedNotchSize = CGSize(width: 200, height: 32)
}

struct MusicControlOverlay: View {
    let notchHeight: CGFloat
    let cornerRadius: CGFloat
    var body: some View { Color.clear.frame(width: 120, height: notchHeight) }
}

@main
@MainActor
private struct MusicControlWindowManagerTests {
    static func flush() {
        autoreleasepool {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        }
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        weak var hostingView: NSView?
        weak var replacementHostingView: NSView?
        autoreleasepool {
            let manager = MusicControlWindowManager.shared
            let viewModel = DynamicIslandViewModel()
            let metrics = MusicControlWindowMetrics(notchHeight: 32, notchWidth: 200,
                                                   rightWingWidth: 20, cornerRadius: 8, spacing: 36)
            precondition(manager.present(using: viewModel, metrics: metrics))
            flush()
            guard let window = ScreenCaptureVisibilityManager.shared.window else {
                fatalError("Present must create a panel")
            }
            hostingView = window.contentView
            let frame = window.frame
            precondition(window.isVisible && window.alphaValue > 0.99)

            // A destination display presents before the outgoing display's hide
            // animation completes. Its panel and hosting graph must stay alive.
            manager.hide()
            precondition(manager.present(using: viewModel, metrics: metrics))
            flush()
            precondition(window.isVisible && window.alphaValue > 0.99,
                         "An old hide completion must not hide newly presented controls")
            precondition(window.contentView === hostingView && hostingView != nil,
                         "An old hide completion must not tear down the reused hosting graph")
            precondition(window.frame == frame, "The latest presentation must retain its target frame")

            // Even unchanged metrics must restore visibility during a pending hide.
            manager.hide(tearDown: false)
            precondition(manager.refresh(using: viewModel, metrics: metrics))
            flush()
            precondition(window.isVisible && window.alphaValue > 0.99,
                         "Refresh during hide must present again, including unchanged metrics")

            // An old completion must not clear resources belonging to a new panel.
            manager.hide()
            manager.hide(animated: false)
            precondition(manager.present(using: viewModel, metrics: metrics))
            guard let replacement = ScreenCaptureVisibilityManager.shared.window else {
                fatalError("Present after teardown must create a replacement panel")
            }
            precondition(replacement !== window)
            flush()
            precondition(replacement.isVisible && replacement.alphaValue > 0.99)
            precondition(manager.refresh(using: viewModel, metrics: metrics))
            precondition(ScreenCaptureVisibilityManager.shared.window === replacement,
                         "Old completions must not clear the manager's new panel")

            replacementHostingView = replacement.contentView
            manager.hide()
            flush()
            precondition(!replacement.isVisible && replacement.contentView == nil,
                         "A current hide must still remove the panel and detach its content")
        }
        flush()
        precondition(replacementHostingView == nil && hostingView == nil,
                     "Completed teardown must release the hosting graphs")
    }
}
