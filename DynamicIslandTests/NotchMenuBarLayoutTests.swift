import AppKit
import SwiftUI

@main
@MainActor
private struct NotchMenuBarLayoutTests {
    static func main() {
        _ = NSApplication.shared
        // Distinct colors stand in for left and formerly-right components.
        // Render real SwiftUI layout so a misplaced spacer or anchor fails the test.
        let content = HStack(spacing: 0) {
            Color.red.frame(width: 40, height: 30)
            NotchGap(width: 200, height: 30)
            Color.green.frame(width: 80, height: 30)
            Color.black.frame(width: 200, height: 40)
        }.environment(\.notchContentOnLeft, true)

        let normal = render(NotchPresentationLayout(physicalWidth: 200, leftAligned: 1) {
            content.frame(maxWidth: 500, alignment: .trailing)
        })
        let red = coloredColumns(normal, red: true)
        let green = coloredColumns(normal, red: false)
        precondition(!red.isEmpty && !green.isEmpty, "Both components must remain visible")
        precondition(red.max()! < green.min()!, "Component order must be preserved")
        precondition(green.max()! < 300, "Formerly-right content must be left of the physical notch")
        precondition(green.min()! - red.max()! <= 2, "No hardware-width gap may remain between components")

        let insufficientRoom = render(NotchPresentationLayout(physicalWidth: 200, leftAligned: 1) {
            ViewThatFits(in: .horizontal) {
                content.fixedSize(horizontal: true, vertical: false)
                Color.black.frame(width: 200, height: 40)
            }.frame(maxWidth: 250, alignment: .trailing)
        })
        precondition(coloredColumns(insufficientRoom, red: true).isEmpty,
                     "Hide content when it would cover application menus")
        precondition(coloredColumns(insufficientRoom, red: false).isEmpty,
                     "The formerly-right component must also be hidden when space is insufficient")
        let open = render(NotchPresentationLayout(physicalWidth: 200, leftAligned: 0) {
            Color.red.frame(width: 600, height: 40)
        })
        let openColumns = coloredColumns(open, red: true)
        precondition(abs((openColumns.first! + openColumns.last!) / 2 - 400) <= 1,
                     "Expanded content must remain centered on the hardware notch")
        let intermediate = render(NotchPresentationLayout(physicalWidth: 200, leftAligned: 0.5) {
            Color.red.frame(width: 600, height: 40)
        })
        let intermediateColumns = coloredColumns(intermediate, red: true)
        precondition(abs(intermediateColumns.first! - 0) <= 1,
                     "Alignment must support intermediate animation positions")

        let standard = render(HStack(spacing: 0) {
            Color.red.frame(width: 40, height: 30)
            NotchGap(width: 200, height: 30)
            Color.green.frame(width: 80, height: 30)
        })
        let standardRed = coloredColumns(standard, red: true)
        let standardGreen = coloredColumns(standard, red: false)
        precondition(abs(standardGreen.min()! - standardRed.max()! - 201) <= 1,
                     "Displays without left-side layout must retain the original notch gap")
        print("NotchMenuBarLayoutTests passed")
    }

    static func render<V: View>(_ content: V) -> NSBitmapImageRep {
        let host = NSHostingView(rootView:
            ZStack(alignment: .top) { content }
                .frame(maxWidth: 800, maxHeight: 60, alignment: .top)
                .frame(width: 800, height: 60, alignment: .top)
        )
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 60)
        host.layoutSubtreeIfNeeded()
        let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }

    static func coloredColumns(_ image: NSBitmapImageRep, red: Bool) -> [Int] {
        let scale = CGFloat(image.pixelsWide) / 800
        return (0..<image.pixelsWide).filter { x in
            (0..<image.pixelsHigh).contains { y in
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.8 else { return false }
                return red ? c.redComponent > 0.8 && c.greenComponent < 0.4
                    : c.greenComponent > 0.4 && c.redComponent < 0.4
            }
        }.map { Int(CGFloat($0) / scale) }
    }
}
