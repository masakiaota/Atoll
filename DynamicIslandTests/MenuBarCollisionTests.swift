import Foundation
import CoreGraphics

@main
private struct MenuBarCollisionTests {
    static func main() {
        let notch = CGRect(x: 691, y: 0, width: 150, height: 32)
        func check(_ right: CGFloat, _ current: Bool, _ expected: Bool) {
            let item = CGRect(x: 0, y: 0, width: right, height: 24)
            precondition(MenuBarCollision.shouldRetract(items: [item], notch: notch, currentlyRetracted: current) == expected)
        }
        check(687, false, false) // Exactly 4pt: no entry.
        check(687.5, false, true)
        check(679, true, false) // Exactly 12pt: exit.
        check(679.5, true, true)
        let icon = CGRect(x: 844, y: 0, width: 20, height: 24)
        precondition(MenuBarCollision.shouldRetract(items: [icon], notch: notch, currentlyRetracted: false))
        precondition(!MenuBarCollision.shouldRetract(items: [], notch: notch, currentlyRetracted: true))
        let shifted = notch.offsetBy(dx: -1532, dy: 500)
        precondition(MenuBarCollision.shouldRetract(items: [icon.offsetBy(dx: -1532, dy: 500)], notch: shifted, currentlyRetracted: false))
        let wider = CGRect(x: 600, y: 0, width: 332, height: 32)
        precondition(MenuBarCollision.shouldRetract(items: [CGRect(x: 620, y: 0, width: 20, height: 24)], notch: wider, currentlyRetracted: false))
    }
}
