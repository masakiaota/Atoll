/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

struct HiddenEdgeHoverPollingState: Equatable, Sendable {
    let screenName: String
    let hidesUntilHover: Bool
    let isNonNotchScreen: Bool
    let isNotchClosed: Bool
    let isSneakPeekVisible: Bool
    let isLocked: Bool

    var shouldPoll: Bool {
        hidesUntilHover
            && isNonNotchScreen
            && isNotchClosed
            && !isSneakPeekVisible
            && !isLocked
    }
}
