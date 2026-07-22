/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Combine
import Foundation

@MainActor
final class FocusTaskManager: ObservableObject {
    static let shared = FocusTaskManager()

    @Published private(set) var selectedTask: ReminderItem?
    @Published private(set) var accumulatedElapsed: TimeInterval = 0
    @Published private(set) var runningSince: Date?
    @Published private(set) var isCompleting = false
    @Published private(set) var completionError: String?

    private let calendarManager: CalendarManager
    private var remindersCancellable: AnyCancellable?

    private init() {
        calendarManager = .shared
        remindersCancellable = calendarManager.$incompleteReminders
            .dropFirst()
            .sink { [weak self] reminders in
                self?.reconcileSelection(with: reminders)
            }
    }

    var hasActiveTask: Bool {
        selectedTask != nil
    }

    var isPaused: Bool {
        selectedTask != nil && runningSince == nil
    }

    func select(_ reminder: ReminderItem, at date: Date = Date()) {
        completionError = nil

        if selectedTask?.id == reminder.id {
            selectedTask = reminder
            return
        }

        selectedTask = reminder
        accumulatedElapsed = 0
        runningSince = date
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let runningSince else { return accumulatedElapsed }
        return max(0, accumulatedElapsed + date.timeIntervalSince(runningSince))
    }

    func pause(at date: Date = Date()) {
        guard selectedTask != nil, runningSince != nil else { return }
        accumulatedElapsed = elapsed(at: date)
        runningSince = nil
    }

    func resume(at date: Date = Date()) {
        guard selectedTask != nil, runningSince == nil else { return }
        runningSince = date
    }

    func clear() {
        selectedTask = nil
        accumulatedElapsed = 0
        runningSince = nil
        completionError = nil
    }

    func completeSelectedTask() async {
        guard let task = selectedTask, !isCompleting else { return }

        isCompleting = true
        completionError = nil
        let completed = await calendarManager.setReminderCompleted(
            reminderID: task.id,
            completed: true
        )
        isCompleting = false

        if completed, selectedTask?.id == task.id {
            clear()
        } else if !completed, selectedTask?.id == task.id {
            completionError = calendarManager.reminderMutationError
        }
    }

    private func reconcileSelection(with reminders: [ReminderItem]) {
        guard let selectedTask else { return }
        guard let refreshed = reminders.first(where: { $0.id == selectedTask.id }) else {
            clear()
            return
        }
        self.selectedTask = refreshed
    }
}

enum FocusTaskDurationFormatter {
    static func string(from interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
