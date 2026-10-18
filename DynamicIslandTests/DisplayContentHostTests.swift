import AppKit
import Combine
import SwiftUI

@main
@MainActor
private struct DisplayContentHostTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        testInactiveDisplayDoesNotBuildContent()
        testScreenSwitchReleasesHostingGraph()
        testOpenNotchSurvivesPointerLeaving()
        testRepeatedSwitchingAndTeardown()
    }

    static func flush() {
        autoreleasepool {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    static func testInactiveDisplayDoesNotBuildContent() {
        let probe = Probe()
        let host = probe.makeHost(active: false)
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        host.layoutSubtreeIfNeeded()
        precondition(probe.created == 0, "Inactive displays must not construct the heavy view")
        precondition(host.subviews.count == 1)
        precondition(host.subviews[0].frame == host.bounds, "The placeholder must fill the window canvas")
        host.isPointerOnScreen = false
        precondition(probe.placeholderCount == 1, "Mouse movement within a screen must not rebuild views")
        host.isPointerOnScreen = true
        precondition(probe.created == 1)
        precondition(host.subviews[0].frame == host.bounds, "Restored content must inherit the window size")
    }

    static func testScreenSwitchReleasesHostingGraph() {
        let first = Probe()
        let second = Probe()
        let (firstHost, secondHost) = autoreleasepool {
            (first.makeHost(active: true), second.makeHost(active: false))
        }
        flush()
        precondition(first.created == 1 && second.created == 0)
        autoreleasepool {
            firstHost.isPointerOnScreen = false
            secondHost.isPointerOnScreen = true
        }
        flush()
        precondition(first.teardowns == 1)
        precondition(first.lastHostingView == nil, "Leaving a closed display must release its NSHostingView")
        precondition(first.lastPayload == nil, "The old SwiftUI root must release its retained payload")
        precondition(second.created == 1 && second.lastHostingView != nil)
    }

    static func testOpenNotchSurvivesPointerLeaving() {
        let probe = Probe()
        let host = probe.makeHost(active: true)
        let original = host.subviews.first
        host.isNotchOpen = true
        host.isPointerOnScreen = false
        precondition(host.subviews.first === original, "An open tab must keep its view and local state")
        precondition(probe.teardowns == 0)
        host.isNotchOpen = false
        precondition(probe.teardowns == 1, "Closing an inactive notch must release its content")

        // A shortcut can open a notch before a native mouse event is delivered.
        host.isNotchOpen = true
        precondition(probe.created == 2, "Programmatic opening must restore full content")
        host.isPointerOnScreen = true
        host.isNotchOpen = false
        precondition(probe.teardowns == 1, "Closing on the pointer's screen keeps the regular closed activities")
    }

    static func testRepeatedSwitchingAndTeardown() {
        let probe = Probe()
        var host: DisplayContentHost? = autoreleasepool { probe.makeHost(active: false) }
        weak var weakHost = host
        for _ in 0..<10 {
            autoreleasepool {
                host!.isPointerOnScreen = true
                host!.isPointerOnScreen = true
                host!.isPointerOnScreen = false
            }
            flush()
            precondition(probe.lastHostingView == nil && probe.lastPayload == nil)
        }
        precondition(probe.created == 10 && probe.teardowns == 10)
        let updates = PassthroughSubject<Bool, Never>()
        updates.sink { [weak host] open in host?.isNotchOpen = open }.store(in: &host!.cancellables)
        host = nil
        flush()
        updates.send(true)
        precondition(weakHost == nil, "Display removal must release its subscriptions and host")
        precondition(probe.created == 10, "Late updates must not recreate a removed display")
    }
}

@MainActor
private final class Probe {
    var created = 0
    var placeholderCount = 0
    var teardowns = 0
    weak var lastHostingView: NSView?
    weak var lastPayload: Payload?

    func makeHost(active: Bool) -> DisplayContentHost {
        DisplayContentHost(
            isPointerOnScreen: active,
            isNotchOpen: false,
            makeContent: {
                self.created += 1
                let payload = Payload()
                let view = NSHostingView(rootView: PayloadView(payload: payload))
                self.lastPayload = payload
                self.lastHostingView = view
                return view
            },
            makePlaceholder: {
                self.placeholderCount += 1
                return NSView()
            },
            releaseContent: {
                precondition(self.lastHostingView?.superview != nil,
                             "Cancel tasks and clear teardown hooks before detaching content")
                self.teardowns += 1
            }
        )
    }
}

private final class Payload: ObservableObject {
    let bytes = Data(repeating: 0x42, count: 1_048_576)
}

private struct PayloadView: View {
    @ObservedObject var payload: Payload
    var body: some View { Text("\(payload.bytes.count)") }
}
