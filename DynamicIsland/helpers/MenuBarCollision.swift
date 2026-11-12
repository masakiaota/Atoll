import Foundation
import CoreGraphics

/// Horizontal clearance only; callers supply items from the same screen.
enum MenuBarCollision {
    static func shouldRetract(items: [CGRect], notch: CGRect, currentlyRetracted: Bool) -> Bool {
        let clearance: CGFloat = currentlyRetracted ? 12 : 4
        let left = notch.minX - clearance
        let right = notch.maxX + clearance
        for item in items where item.width > 0 {
            if item.maxX > left && item.minX < right { return true }
        }
        return false
    }
}
