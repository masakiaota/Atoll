private func state(
    screenName: String = "External Display",
    hidesUntilHover: Bool = true,
    isNonNotchScreen: Bool = true,
    isNotchClosed: Bool = true,
    isSneakPeekVisible: Bool = false,
    isLocked: Bool = false
) -> HiddenEdgeHoverPollingState {
    HiddenEdgeHoverPollingState(
        screenName: screenName,
        hidesUntilHover: hidesUntilHover,
        isNonNotchScreen: isNonNotchScreen,
        isNotchClosed: isNotchClosed,
        isSneakPeekVisible: isSneakPeekVisible,
        isLocked: isLocked
    )
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

@main
private struct HiddenEdgeHoverPollingStateTests {
    static func main() {
        expect(state().shouldPoll, "Eligible closed external display should poll")
        expect(!state(hidesUntilHover: false).shouldPoll, "Disabled setting should stop polling")
        expect(!state(isNonNotchScreen: false).shouldPoll, "Physical-notch display should stop polling")
        expect(!state(isNotchClosed: false).shouldPoll, "Opening the notch should stop polling")
        expect(!state(isSneakPeekVisible: true).shouldPoll, "Sneak peek should stop polling")
        expect(!state(isLocked: true).shouldPoll, "Locking should stop polling")

        let unlockTransition = [state(isLocked: true), state()]
        expect(unlockTransition.map(\.shouldPoll) == [false, true], "Unlock should restart polling")

        let sneakPeekTransition = [state(isSneakPeekVisible: true), state()]
        expect(sneakPeekTransition.map(\.shouldPoll) == [false, true], "Sneak peek completion should restart polling")

        let screenReconfiguration = [
            state(screenName: "Built-in Display", isNonNotchScreen: false),
            state(screenName: "External Display", isNonNotchScreen: true),
        ]
        expect(screenReconfiguration.map(\.shouldPoll) == [false, true], "Screen reconfiguration should restart polling")

        let rapidRestart = [state(), state(isNotchClosed: false), state()]
        expect(rapidRestart.map(\.shouldPoll) == [true, false, true], "Rapid stop and restart should preserve eligibility")

        let firstScreen = state(screenName: "External Display 1")
        let secondScreen = state(screenName: "External Display 2")
        expect(firstScreen != secondScreen, "Screen identity should restart the SwiftUI task")
    }
}
