/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// Runtime context flags used to keep the app's launch deterministic on CI.
enum AppRuntimeEnvironment {
    /// This fork is used from local builds and does not publish a signed update feed.
    /// Keep Sparkle dormant until a fork-owned feed and signing key are configured.
    static let softwareUpdatesEnabled = false

    /// Third-party extension integrations are intentionally dormant in this fork.
    /// Keep their implementation available for a later, deliberate opt-in.
    static let thirdPartyExtensionsEnabled = false

    /// `true` only in DEBUG builds launched by XCUITest (`--uitesting`); always false in Release.
    static let isUITesting: Bool = {
        #if DEBUG
        return CommandLine.arguments.contains("--uitesting")
        #else
        return false
        #endif
    }()

    /// Forces the single-display window path for display reconciliation UI tests.
    static let forcesSingleDisplayForUITesting: Bool = {
        #if DEBUG
        return isUITesting
            && CommandLine.arguments.contains("--uitesting-force-single-display")
        #else
        return false
        #endif
    }()

    /// Exercises reconciliation repeatedly after the initial panel is visible.
    static let repeatsDisplayModeNotificationForUITesting: Bool = {
        #if DEBUG
        return isUITesting
            && CommandLine.arguments.contains("--uitesting-repeat-display-mode-notifications")
        #else
        return false
        #endif
    }()
}
