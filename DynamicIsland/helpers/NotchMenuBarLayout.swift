import AppKit
import SwiftUI

extension NSScreen {
    /// The hardware cutout, independent of Atoll's configurable closed size.
    var physicalNotchFrame: CGRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaInsets.top,
                      width: right.minX - left.maxX, height: safeAreaInsets.top)
    }
}

private struct NotchContentOnLeftKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var notchContentOnLeft: Bool {
        get { self[NotchContentOnLeftKey.self] }
        set { self[NotchContentOnLeftKey.self] = newValue }
    }
}

/// A hardware spacer is unnecessary between components when they all live on the left.
struct NotchGap: View {
    @Environment(\.notchContentOnLeft) private var onLeft
    var width: CGFloat
    var height: CGFloat? = nil

    var body: some View {
        Color.black.frame(width: onLeft ? 0 : max(0, width), height: height)
    }
}

/// The native window stays centered. Only the closed surface is anchored to
/// the hardware notch's right edge; open/close placement animates in this canvas.
struct NotchPresentationLayout: Layout {
    var physicalWidth: CGFloat
    var leftAligned: CGFloat

    var animatableData: CGFloat {
        get { leftAligned }
        set { leftAligned = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(proposal)
        let shift = leftAligned * ((bounds.width + physicalWidth) / 2 - size.width)
        view.place(at: CGPoint(x: bounds.minX + shift, y: bounds.minY), anchor: .topLeading,
                   proposal: ProposedViewSize(size))
    }
}
