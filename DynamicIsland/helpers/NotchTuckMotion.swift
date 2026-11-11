import QuartzCore
import SwiftUI

/// The one motion for the whole notch leaving or returning: it tucks up into
/// the top edge of the screen and comes back down from it.
///
/// Leaving accelerates and is short, so the notch gets out of the way at once.
/// Returning decelerates without overshoot, because a notch that bounces below
/// the screen edge would show a gap above it.
enum NotchTuckMotion {
    static let hideDuration: TimeInterval = 0.2
    static let showDuration: TimeInterval = 0.36
    private static let hideCurve: (Float, Float, Float, Float) = (0.4, 0, 1, 1)
    private static let showCurve: (Float, Float, Float, Float) = (0.16, 1, 0.3, 1)

    static func duration(hiding: Bool) -> TimeInterval { hiding ? hideDuration : showDuration }

    static func animation(hiding: Bool) -> Animation {
        let c = hiding ? hideCurve : showCurve
        return .timingCurve(Double(c.0), Double(c.1), Double(c.2), Double(c.3), duration: duration(hiding: hiding))
    }

    static func timingFunction(hiding: Bool) -> CAMediaTimingFunction {
        let c = hiding ? hideCurve : showCurve
        return CAMediaTimingFunction(controlPoints: c.0, c.1, c.2, c.3)
    }
}
