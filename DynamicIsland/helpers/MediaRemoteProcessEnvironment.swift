/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

/// Environment used for the validated MediaRemote adapter launch boundary.
///
/// The Perl wrapper and the adapter receive every input they need through
/// their fixed arguments and, for streaming, one Atoll-controlled descriptor
/// marker. They do not need PATH, HOME, TMPDIR, locale, or any inherited
/// value. This prevents user-controlled PERL*, DYLD_*, MEDIAREMOTEADAPTER_*,
/// NOWPLAYING_CLIENT, and similar variables from influencing the process.
enum MediaRemoteProcessEnvironment {
    static let launchEnvironment: [String: String] = [:]
    private static let descriptorEnvironment = [
        "ATOLL_MEDIAREMOTE_EXECUTABLE": "/dev/fd/0"
    ]

    static func apply(to process: Process, frameworkFromStandardInput: Bool = false) {
        process.environment = frameworkFromStandardInput
            ? descriptorEnvironment
            : launchEnvironment
    }
}
