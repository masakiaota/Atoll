import XCTest
import AppKit

final class DynamicIslandUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // App launches and stays alive without crashing.
    func testAppLaunchesWithoutCrashing() throws {
        let isRunning = app.wait(for: .runningForeground, timeout: 10.0)
            || app.wait(for: .runningBackground, timeout: 10.0)
        XCTAssertTrue(isRunning, "App should be running after launch.")
        XCTAssertNotEqual(app.state, .notRunning, "App should not have terminated.")
    }

    // The notch panel is present and exposed to accessibility.
    func testNotchExpansion() throws {
        let notch = app.descendants(matching: .any)["AtollNotch"]
        XCTAssertTrue(notch.waitForExistence(timeout: 15.0), "The Atoll notch should be visible.")
    }

    // Repeated display-mode reconciliation must reuse the single managed panel.
    func testRepeatedDisplayModeReconciliationDoesNotDuplicateNotch() throws {
        app.terminate()
        app.launchArguments = [
            "--uitesting",
            "--uitesting-force-single-display",
            "--uitesting-repeat-display-mode-reconciliation",
        ]
        app.launch()

        let notches = app.descendants(matching: .any).matching(identifier: "AtollNotch")
        XCTAssertTrue(
            notches.firstMatch.waitForExistence(timeout: 15.0),
            "The initial Atoll notch should be visible."
        )

        XCTAssertEqual(
            notches.count,
            1,
            "Repeated display reconciliation should leave exactly one notch."
        )
    }

    func testInactiveDisplaysRestoreContentOnPointerEntry() throws {
        app.terminate()
        // Typed argument-domain defaults do not change the user's stored settings.
        app.launchArguments = [
            "--uitesting",
            "--uitesting-force-all-displays",
        ]
        app.launch()

        let notches = app.descendants(matching: .any).matching(identifier: "AtollNotch")
        let inactive = app.descendants(matching: .any).matching(identifier: "AtollInactiveNotch")
        let displayCount = NSScreen.screens.count
        func waitForDisplayCounts() {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                notches.count == 1 && inactive.count == displayCount - 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed,
                           "Expected 1 normal / \(displayCount - 1) inactive; got \(notches.count) / \(inactive.count)")
        }
        waitForDisplayCounts()
        for _ in 0..<(displayCount - 1) {
            let target = inactive.firstMatch
            let targetFrame = target.frame
            // The native panel passes mouse events through until the pointer
            // reaches its surface, so element-level hit testing rejects hover.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            waitForDisplayCounts()
            XCTAssertTrue(notches.firstMatch.frame.intersects(targetFrame),
                          "Entering an inactive display should restore its normal content")
        }
    }

    func testSystemHUDObservationRequiresAnEnabledStyleAndControl() {
        XCTAssertFalse(shouldObserveHUD(style: false, volume: true))
        XCTAssertFalse(shouldObserveHUD(style: false, volume: true, brightness: true, backlight: true))
        XCTAssertFalse(shouldObserveHUD(style: true))
        XCTAssertTrue(shouldObserveHUD(style: true, volume: true))
        XCTAssertTrue(shouldObserveHUD(style: true, brightness: true))
        XCTAssertTrue(shouldObserveHUD(style: true, backlight: true))
    }

    private func shouldObserveHUD(
        style: Bool,
        volume: Bool = false,
        brightness: Bool = false,
        backlight: Bool = false
    ) -> Bool {
        SystemHUDObservationPolicy.shouldObserve(
            hasEnabledStyle: style,
            volumeEnabled: volume,
            brightnessEnabled: brightness,
            keyboardBacklightEnabled: backlight
        )
    }
}
