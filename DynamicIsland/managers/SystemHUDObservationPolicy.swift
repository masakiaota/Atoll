/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

enum SystemHUDObservationPolicy {
    static func shouldObserve(
        hasEnabledStyle: Bool,
        volumeEnabled: Bool,
        brightnessEnabled: Bool,
        keyboardBacklightEnabled: Bool
    ) -> Bool {
        hasEnabledStyle
            && (volumeEnabled || brightnessEnabled || keyboardBacklightEnabled)
    }
}
