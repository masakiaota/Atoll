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

import AppKit
import Foundation
import Darwin

@MainActor
final class MemoryUsageMonitor {
    static let shared = MemoryUsageMonitor()

#if DEBUG
    private let thresholdBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
#else
    private let thresholdBytes: UInt64 = 1_024 * 1_024 * 1_024
#endif
    private let pollInterval: TimeInterval = 8 // Clamp within 5-10 seconds to limit battery impact
    private let quitPromptCooldown: TimeInterval = 300
    private let logSampleInterval: TimeInterval = 300
    private var monitorTask: Task<Void, Never>?
    private var lastQuitPrompt: Date = .distantPast
    private var lastLogSample: Date = .distantPast

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.evaluateMemoryFootprint()
                do {
                    try await Task.sleep(for: .seconds(self.pollInterval))
                } catch {
                    break
                }
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func evaluateMemoryFootprint() async {
        guard let usage = currentResidentSize() else { return }
        if usage >= thresholdBytes {
            promptToQuitIfNeeded(currentUsage: usage)
        } else if Date().timeIntervalSince(lastLogSample) >= logSampleInterval {
            lastLogSample = Date()
            Logger.log("[MemoryMonitor] Resident usage: \(formatMegabytes(usage)) MB", category: .memory)
        }
    }

    private func promptToQuitIfNeeded(currentUsage: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastQuitPrompt) >= quitPromptCooldown else {
            Logger.log("[MemoryMonitor] Usage \(formatMegabytes(currentUsage)) MB exceeds threshold but cooldown active", category: .warning)
            return
        }
        lastQuitPrompt = now
        Logger.log("[MemoryMonitor] Usage \(formatMegabytes(currentUsage)) MB >= \(formatMegabytes(thresholdBytes)) MB. Prompting to quit.", category: .warning)
        presentQuitAlert(currentUsage: currentUsage)
    }

    private func presentQuitAlert(currentUsage: UInt64) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "DynamicIsland memory usage is high"
        alert.informativeText = "The app is currently using \(formatMegabytes(currentUsage)) MB, which exceeds the safe limit of \(formatMegabytes(thresholdBytes)) MB. Quit now to free memory? You can reopen Atoll normally afterward."
        alert.addButton(withTitle: "Quit Atoll")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        } else {
            Logger.log("[MemoryMonitor] Quit postponed by user", category: .warning)
        }
    }

    private func currentResidentSize() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            Logger.log("[MemoryMonitor] task_info failed with code \(result)", category: .error)
            return nil
        }
        return UInt64(info.resident_size)
    }

    private func formatMegabytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.1f", mb)
    }
}
