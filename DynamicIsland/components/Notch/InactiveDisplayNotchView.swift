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
        let retracted = physical == nil && vm.isRetractedForMenuBar
        let shape = retracted
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 2,
                                             bottomTrailingRadius: 2, topTrailingRadius: 0))
            : island
            ? AnyShape(DynamicIslandPillShape(cornerRadius: max(
                vm.closedNotchSize.height / 2, dynamicIslandPillCornerRadiusInsets.closed.standard
            )))
            : AnyShape(NotchShape())
        let height = physical?.height ?? vm.effectiveClosedNotchHeight

        AtollCollapsedSurface(
            width: physical?.width ?? vm.closedNotchSize.width,
            height: retracted ? 3 : (hideNonNotchUntilHover && physical == nil ? 0 : height),
            shape: shape
        )
        .animation(NotchTuckMotion.animation(hiding: retracted), value: retracted)
        .background(NotchMouseRegion(shape: shape))
        .contentShape(shape)
        .onTapGesture { vm.open() }
        .padding(.top, island && !retracted ? dynamicIslandTopOffset : 0)
        .offset(y: vm.isTuckedForMissionControl ? -(vm.closedNotchSize.height + 12) : 0)
        .opacity(vm.isTuckedForMissionControl ? 0 : 1)
        .animation(NotchTuckMotion.animation(hiding: vm.isTuckedForMissionControl), value: vm.isTuckedForMissionControl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Atoll")
        .accessibilityIdentifier("AtollInactiveNotch")
    }
}
