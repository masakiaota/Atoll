import AppKit
import SwiftUI

// Standalone regression test, compiled with DynamicIslandWindow.swift. The
// capture registry is unrelated to window geometry and is not started here.
@MainActor
final class ScreenCaptureVisibilityManager {
    static let shared = ScreenCaptureVisibilityManager()
    enum Scope { case entireInterface }
    func register(_ window: NSWindow, scope: Scope) {}
}

@main
@MainActor
private struct NotchMouseRegionTests {
    static func main() {
        _ = NSApplication.shared
        let window = DynamicIslandWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 300),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        let host = NSHostingView(rootView:
            Color.black.frame(width: 320, height: 40)
                .background(NotchMouseRegion(shape: AnyShape(RoundedRectangle(cornerRadius: 10))))
                .frame(width: 800, height: 300, alignment: .topTrailing)
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let region = window.mouseRegion else { fatalError("Surface must register its native input region") }
        func screenPoint(_ local: CGPoint) -> CGPoint {
            window.convertPoint(toScreen: region.convert(local, to: nil))
        }
        precondition(region.bounds.size == CGSize(width: 320, height: 40), "Padding must not enter the input region")
        precondition(region.containsScreenPoint(screenPoint(CGPoint(x: 160, y: 20))))
        precondition(!region.containsScreenPoint(screenPoint(CGPoint(x: 321, y: 20))), "Right-side menu clicks must pass through")
        precondition(!region.containsScreenPoint(screenPoint(CGPoint(x: -1, y: 20))), "Left transparent padding must pass through")
        precondition(!region.containsScreenPoint(screenPoint(CGPoint(x: 160, y: 41))), "Shadow below the surface must pass through")
        precondition(!region.containsScreenPoint(screenPoint(CGPoint(x: 1, y: 1))), "Rounded transparent corners must pass through")

        // Move an unshown window around the existing cursor, without moving the
        // user's pointer or posting synthetic events to other applications.
        let inside = screenPoint(CGPoint(x: 160, y: 20))
        let mouse = NSEvent.mouseLocation
        window.setFrame(window.frame.offsetBy(dx: mouse.x - inside.x, dy: mouse.y - inside.y), display: false)
        precondition(!window.ignoresMouseEvents, "Atoll's visible surface must remain interactive")
        window.suppressMouseEvents = true
        precondition(window.ignoresMouseEvents, "Menu overflow must disable every Atoll input region")
        window.suppressMouseEvents = false
        precondition(!window.ignoresMouseEvents, "Input must recover after menu overflow closes")
        window.setFrame(window.frame.offsetBy(dx: -1000, dy: 0), display: false)
        precondition(window.ignoresMouseEvents, "A layout change must release input without waiting for mouse movement")

        guard let screen = NSScreen.screens.first else { fatalError("The test requires a screen") }
        // The preceding input test deliberately moves the panel off the pointer
        // and can leave it entirely offscreen. Restore a known screen first.
        window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2,
                                      y: screen.frame.midY - window.frame.height / 2))
        precondition(window.screen === screen, "The panel must belong to the screen under test")
        var screenChanges: [Bool] = []
        window.onPointerScreenChange = { screenChanges.append($0) }
        let outside = CGPoint(x: screen.frame.minX - 100, y: screen.frame.minY - 100)
        let insideScreen = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        window.updateMouseEventPassthrough(at: outside)
        screenChanges.removeAll()
        window.updateMouseEventPassthrough(at: insideScreen)
        window.updateMouseEventPassthrough(at: insideScreen)
        window.updateMouseEventPassthrough(at: outside)
        precondition(screenChanges == [true, false],
                     "Screen entry and exit must notify once, without rebuilding for every mouse move")
        window.close()
        window.updateMouseEventPassthrough(at: insideScreen)
        precondition(screenChanges == [true, false], "Closed windows must not reactivate their content")
    }
}
