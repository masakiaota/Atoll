import Defaults
import SwiftUI

/// An inactive display retains its silhouette, without the activity graphs or
/// their subscriptions. Entering the display restores the regular ContentView.
struct InactiveDisplayNotchView: View {
    @ObservedObject var vm: DynamicIslandViewModel
    @Default(.externalDisplayStyle) private var externalDisplayStyle
    @Default(.hideNonNotchUntilHover) private var hideNonNotchUntilHover

    var body: some View {
        let physical = vm.physicalNotchFrame
        let island = physical == nil && externalDisplayStyle == .dynamicIsland
        let shape = island
            ? AnyShape(DynamicIslandPillShape(cornerRadius: max(
                vm.closedNotchSize.height / 2, dynamicIslandPillCornerRadiusInsets.closed.standard
            )))
            : AnyShape(NotchShape())
        let height = physical?.height ?? vm.effectiveClosedNotchHeight

        AtollCollapsedSurface(
            width: physical?.width ?? vm.closedNotchSize.width,
            height: hideNonNotchUntilHover && physical == nil ? 0 : height,
            shape: shape
        )
        .background(NotchMouseRegion(shape: shape))
        .contentShape(shape)
        .onTapGesture { vm.open() }
        .padding(.top, island ? dynamicIslandTopOffset : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Atoll")
        .accessibilityIdentifier("AtollInactiveNotch")
    }
}
