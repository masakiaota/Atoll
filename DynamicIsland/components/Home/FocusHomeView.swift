/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Defaults
import EventKit
import SwiftUI

struct FocusHomeView: View {
    private enum Detail {
        case camera
    }

    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var focusTaskManager = FocusTaskManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var webcamManager = WebcamManager.shared

    @Default(.showMirror) private var showMirror
    @Default(.showStandardMediaControls) private var showStandardMediaControls

    @State private var selectedDate = Date()
    @State private var detail: Detail?

    private var shouldShowMusicPlayer: Bool {
        showStandardMediaControls && musicManager.hasActiveSession
    }

    private var shouldShowLiveStrip: Bool {
        focusTaskManager.hasActiveTask || shouldShowMusicPlayer
    }

    private var scheduleEvents: [EventModel] {
        calendarManager.events.filter { !$0.type.isReminder }
    }

    var body: some View {
        Group {
            switch detail {
            case .camera:
                detailHeader(title: "Mirror") {
                    CameraPreviewView(webcamManager: webcamManager)
                        .scaledToFit()
                }
            case nil:
                dashboard
            }
        }
        .task {
            let calendarStatus = EKEventStore.authorizationStatus(for: .event)
            if calendarStatus == .notDetermined || calendarStatus != calendarManager.calendarAuthorizationStatus {
                await calendarManager.checkCalendarAuthorization()
            }
            let reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
            if reminderStatus == .notDetermined || reminderStatus != calendarManager.reminderAuthorizationStatus {
                await calendarManager.checkReminderAuthorization()
            }
            await calendarManager.updateCurrentDate(selectedDate)
            await calendarManager.refreshIncompleteReminders()
        }
        .onChange(of: selectedDate) { _, date in
            Task { await calendarManager.updateCurrentDate(date) }
        }
    }

    @ViewBuilder
    private var dashboard: some View {
        VStack(spacing: 8) {
            if shouldShowLiveStrip {
                liveStrip
                    .frame(height: 54)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 8) {
                    FourWeekCalendarView(selectedDate: $selectedDate)
                        .frame(height: 182)
                    NoDateReminderPane(openReminders: openReminders)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                DayTimelinePane(
                    selectedDate: selectedDate,
                    events: scheduleEvents,
                    authorizationStatus: calendarManager.calendarAuthorizationStatus,
                    hasCalendarAccess: calendarManager.hasCalendarAccess,
                    openCalendar: openCalendar,
                    openReminders: openReminders
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) { mirrorButton }
    }

    @ViewBuilder
    private var liveStrip: some View {
        if focusTaskManager.hasActiveTask && shouldShowMusicPlayer {
            GeometryReader { geometry in
                let musicWidth = min(max(geometry.size.width * 0.36, 220), 290)
                HStack(spacing: 10) {
                    FocusTaskCard()
                        .frame(maxWidth: .infinity)
                    CompactMusicActivity()
                        .frame(width: musicWidth)
                }
            }
        } else if focusTaskManager.hasActiveTask {
            FocusTaskCard()
        } else if shouldShowMusicPlayer {
            CompactMusicActivity()
        }
    }

    private func openCalendar() {
        openApplication(bundleIdentifier: "com.apple.iCal")
    }

    private func openReminders() {
        openApplication(bundleIdentifier: "com.apple.reminders")
    }

    private func openApplication(bundleIdentifier: String) {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    @ViewBuilder
    private var mirrorButton: some View {
        if showMirror && webcamManager.cameraAvailable {
            Button {
                withAnimation(.smooth(duration: 0.2)) { detail = .camera }
            } label: {
                Image(systemName: "camera.fill")
                    .frame(width: 26, height: 26)
                    .background(Color.black.opacity(0.75), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(5)
            .accessibilityLabel("Open mirror")
        }
    }

    private func detailHeader<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    withAnimation(.smooth(duration: 0.2)) { detail = nil }
                } label: {
                    Label("Home", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 48, height: 1)
            }
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FourWeekCalendarView: View {
    @Binding var selectedDate: Date
    @State private var rangeStart: Date

    private static var mondayCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar
    }

    init(selectedDate: Binding<Date>) {
        _selectedDate = selectedDate
        _rangeStart = State(initialValue: Self.rangeStart(containing: selectedDate.wrappedValue))
    }

    private var days: [Date] {
        (0..<28).compactMap { Self.mondayCalendar.date(byAdding: .day, value: $0, to: rangeStart) }
    }

    private var title: String {
        guard let end = days.last else { return "" }
        let startText = rangeStart.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                rangeButton("chevron.left", offset: -28)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    select(Date())
                } label: {
                    Label("Today", systemImage: "calendar")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Today")
                rangeButton("chevron.right", offset: 28)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { date in
                    Text(date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(Array(days[(week * 7)..<(week * 7 + 7)]), id: \.self) { date in
                            dayButton(date)
                        }
                    }
                    if week < 3 {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: selectedDate) { _, date in
            guard let rangeEnd = Self.mondayCalendar.date(byAdding: .day, value: 28, to: rangeStart) else { return }
            if date < rangeStart || date >= rangeEnd {
                rangeStart = Self.rangeStart(containing: date)
            }
        }
        .accessibilityIdentifier("focus-four-week-calendar")
    }

    private func rangeButton(_ icon: String, offset: Int) -> some View {
        Button {
            guard
                let nextRangeStart = Self.mondayCalendar.date(byAdding: .day, value: offset, to: rangeStart),
                let nextSelectedDate = Self.mondayCalendar.date(byAdding: .day, value: offset, to: selectedDate)
            else { return }
            rangeStart = nextRangeStart
            selectedDate = nextSelectedDate
        } label: {
            Image(systemName: icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offset < 0 ? "Previous four weeks" : "Next four weeks")
    }

    private func select(_ date: Date) {
        selectedDate = date
        if Self.mondayCalendar.isDateInToday(date) {
            rangeStart = Self.rangeStart(containing: date)
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let selected = Self.mondayCalendar.isDate(date, inSameDayAs: selectedDate)
        let today = Self.mondayCalendar.isDateInToday(date)
        let weekday = Self.mondayCalendar.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7

        return Button {
            select(date)
        } label: {
            Text(date.formatted(.dateTime.day()))
                .font(.caption.weight(selected ? .bold : .medium))
                .foregroundStyle(selected ? Color.white : (isWeekend ? Color.secondary.opacity(0.8) : Color.secondary))
                .frame(width: 27, height: 25)
                .background {
                    if selected {
                        Circle().fill(Color.accentColor)
                    } else if today {
                        Circle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 31)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(selected ? "Selected" : (today ? "Today" : ""))
    }

    private static func rangeStart(containing date: Date) -> Date {
        let weekStart = mondayCalendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? mondayCalendar.startOfDay(for: date)
        return mondayCalendar.date(byAdding: .day, value: -14, to: weekStart) ?? weekStart
    }
}

private struct FocusTaskCard: View {
    @ObservedObject private var manager = FocusTaskManager.shared

    var body: some View {
        HStack(spacing: 11) {
            if manager.selectedTask == nil {
                Image(systemName: "checklist")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            } else {
                FocusTaskIndicator()
            }

            if let task = manager.selectedTask {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(task.calendar.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 5)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(FocusTaskDurationFormatter.string(from: manager.elapsed(at: context.date)))
                        .font(.system(.body, design: .monospaced, weight: .semibold))
                        .contentTransition(.numericText())
                }
                focusControlButton(
                    manager.isPaused ? "play.fill" : "pause.fill",
                    label: manager.isPaused ? "Resume task" : "Pause task"
                ) {
                    if manager.isPaused {
                        manager.resume()
                    } else {
                        manager.pause()
                    }
                }
                focusControlButton("xmark", label: "Clear focus task") {
                    manager.clear()
                }
                focusControlButton("checkmark", label: "Complete reminder", tint: .green) {
                    Task { await manager.completeSelectedTask() }
                }
                .disabled(manager.isCompleting)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select a reminder")
                        .font(.headline)
                    Text("It will stay visible while you work")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityIdentifier("focus-task-card")
    }

    private func focusControlButton(
        _ icon: String,
        label: LocalizedStringKey,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(tint.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct FocusTaskIndicator: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.7), lineWidth: 2)
            Circle()
                .fill(Color.accentColor)
                .frame(width: max(4, size * 0.26), height: max(4, size * 0.26))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum DayTimelineItem: Identifiable {
    case event(EventModel)
    case reminder(ReminderItem)

    var id: String {
        switch self {
        case .event(let event): "event:\(event.id)"
        case .reminder(let reminder): "reminder:\(reminder.id)"
        }
    }

    var date: Date {
        switch self {
        case .event(let event): event.start
        case .reminder(let reminder): reminder.dueDate ?? .distantFuture
        }
    }

    var sortPriority: Int {
        switch self {
        case .event(let event): event.isAllDay ? 0 : 1
        case .reminder: 2
        }
    }
}

private struct DayTimelinePane: View {
    @Environment(\.openURL) private var openURL
    let selectedDate: Date
    let events: [EventModel]
    let authorizationStatus: EKAuthorizationStatus
    let hasCalendarAccess: Bool
    let openCalendar: () -> Void
    let openReminders: () -> Void

    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var focusTaskManager = FocusTaskManager.shared
    @State private var completingReminderIDs: Set<String> = []

    private var timelineItems: [DayTimelineItem] {
        let eventItems = events.map(DayTimelineItem.event)
        let reminderItems = calendarManager.incompleteReminders.compactMap { reminder -> DayTimelineItem? in
            guard let dueDate = reminder.dueDate,
                  Calendar.current.isDate(dueDate, inSameDayAs: selectedDate) else { return nil }
            return .reminder(reminder)
        }
        return (eventItems + reminderItems).sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.sortPriority < rhs.sortPriority }
            return lhs.date < rhs.date
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Timeline", systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(selectedDate.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                appButton("calendar", label: "Open Calendar", action: openCalendar)
                appButton("checklist", label: "Open Reminders", action: openReminders)
            }
            .padding(.horizontal, 10)

            if let error = calendarManager.reminderMutationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            }

            timeline
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(NotchScrollProtection())
        .accessibilityIdentifier("focus-day-timeline")
    }

    @ViewBuilder
    private var timeline: some View {
        if timelineItems.isEmpty && isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if timelineItems.isEmpty && !hasCalendarAccess {
            emptyMessage("Calendar access is not available.")
        } else if timelineItems.isEmpty {
            emptyMessage("No events or reminders")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(timelineItems) { item in
                        timelineRow(item)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private var isLoading: Bool {
        if authorizationStatus == .notDetermined { return true }
        switch calendarManager.reminderLoadState {
        case .idle, .loading: return true
        case .loaded, .failed: return false
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: DayTimelineItem) -> some View {
        switch item {
        case .event(let event):
            Button {
                if let url = event.calendarAppURL() { openURL(url) }
            } label: {
                eventRow(event)
            }
            .buttonStyle(.plain)
            .help("Open in Calendar")
            .accessibilityLabel("Open \(event.title) in Calendar")
        case .reminder(let reminder):
            reminderRow(reminder)
        }
    }

    private func eventRow(_ event: EventModel) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(event.isAllDay ? String(localized: "All day") : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let detail = eventDetail(event) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func reminderRow(_ reminder: ReminderItem) -> some View {
        ReminderRow(
            reminder: reminder,
            subtitle: reminderSubtitle(reminder),
            isFocused: focusTaskManager.selectedTask?.id == reminder.id,
            isCompleting: completingReminderIDs.contains(reminder.id),
            onComplete: { complete(reminder) },
            onFocus: {
                if focusTaskManager.selectedTask?.id == reminder.id {
                    focusTaskManager.clear()
                } else {
                    focusTaskManager.select(reminder)
                }
            }
        )
    }

    private func complete(_ reminder: ReminderItem) {
        guard !completingReminderIDs.contains(reminder.id) else { return }
        completingReminderIDs.insert(reminder.id)
        Task {
            if focusTaskManager.selectedTask?.id == reminder.id {
                await focusTaskManager.completeSelectedTask()
            } else {
                await calendarManager.setReminderCompleted(reminderID: reminder.id, completed: true)
            }
            completingReminderIDs.remove(reminder.id)
        }
    }

    private func reminderSubtitle(_ reminder: ReminderItem) -> String {
        guard let dueDate = reminder.dueDate else { return reminder.calendar.title }
        return "\(dueDate.formatted(date: .omitted, time: .shortened)) · \(reminder.calendar.title)"
    }

    private func eventDetail(_ event: EventModel) -> String? {
        let names = event.participants
            .filter { !$0.isCurrentUser }
            .map(\.name)
        let people: String? = {
            guard !names.isEmpty else { return nil }
            if names.count <= 2 { return names.joined(separator: ", ") }
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        }()
        let details = [people, event.location]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return details.isEmpty ? event.calendar.title : details.joined(separator: " · ")
    }

    private func appButton(_ icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(label)
    }
}

private struct NoDateReminderPane: View {
    let openReminders: () -> Void

    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var focusTaskManager = FocusTaskManager.shared
    @State private var completingReminderIDs: Set<String> = []

    private var reminders: [ReminderItem] {
        var reminders = calendarManager.incompleteReminders.filter { $0.dueDate == nil }
        if let focused = focusTaskManager.selectedTask, focused.dueDate == nil {
            reminders.removeAll { $0.id == focused.id }
            reminders.insert(focused, at: 0)
        }
        return reminders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("No date", systemImage: "calendar.badge.minus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: openReminders) {
                    HStack(spacing: 3) {
                        Text("Reminders")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.white.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open Reminders")
                .accessibilityLabel("Open Reminders")
            }
            .padding(.horizontal, 10)

            if let error = calendarManager.reminderMutationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
            }

            reminderList
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(NotchScrollProtection())
        .accessibilityIdentifier("no-date-reminder-list")
    }

    @ViewBuilder
    private var reminderList: some View {
        if reminders.isEmpty {
            switch calendarManager.reminderLoadState {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                emptyMessage(message)
            case .loaded:
                emptyMessage("No reminders without a date")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(reminders) { reminder in
                        ReminderRow(
                            reminder: reminder,
                            subtitle: reminder.calendar.title,
                            isFocused: focusTaskManager.selectedTask?.id == reminder.id,
                            isCompleting: completingReminderIDs.contains(reminder.id),
                            onComplete: { complete(reminder) },
                            onFocus: {
                                if focusTaskManager.selectedTask?.id == reminder.id {
                                    focusTaskManager.clear()
                                } else {
                                    focusTaskManager.select(reminder)
                                }
                            }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func complete(_ reminder: ReminderItem) {
        guard !completingReminderIDs.contains(reminder.id) else { return }
        completingReminderIDs.insert(reminder.id)
        Task {
            if focusTaskManager.selectedTask?.id == reminder.id {
                await focusTaskManager.completeSelectedTask()
            } else {
                await calendarManager.setReminderCompleted(reminderID: reminder.id, completed: true)
            }
            completingReminderIDs.remove(reminder.id)
        }
    }
}

private struct ReminderRow: View {
    let reminder: ReminderItem
    let subtitle: String
    let isFocused: Bool
    let isCompleting: Bool
    let onComplete: () -> Void
    let onFocus: () -> Void

    @State private var isHoveringFocus = false
    @State private var isHoveringCompletion = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onComplete) {
                ZStack {
                    Circle()
                        .stroke(Color(nsColor: reminder.calendar.color), lineWidth: 1.5)
                    if isCompleting {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                    } else if isHoveringCompletion {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(nsColor: reminder.calendar.color))
                    }
                }
                .frame(width: 17, height: 17)
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCompleting)
            .onHover { isHoveringCompletion = $0 }
            .help("Complete reminder")
            .accessibilityLabel("Complete \(reminder.title)")

            Button(action: onFocus) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reminder.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 3) {
                        Image(systemName: isFocused && isHoveringFocus ? "xmark" : "scope")
                        Text(isFocused && isHoveringFocus ? "Clear" : (isFocused ? "On" : "Focus"))
                            .lineLimit(1)
                    }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 64, alignment: .trailing)
                        .layoutPriority(1)
                        .opacity(isFocused || isHoveringFocus ? 1 : 0)
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .onHover { isHoveringFocus = $0 }
            .help(isFocused ? "Clear focus task" : "Focus on this reminder")
            .accessibilityLabel(isFocused ? "Clear focus from \(reminder.title)" : "Focus on \(reminder.title)")
            .accessibilityValue(isFocused ? "Focused" : "Not focused")
        }
        .padding(.horizontal, 7)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
    }
}

private struct CompactMusicActivity: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject private var musicManager = MusicManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Button(action: musicManager.openMusicApp) {
                Image(nsImage: musicManager.albumArt)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open music app")
            .accessibilityLabel("Open music app")

            VStack(alignment: .leading, spacing: 1) {
                Text(musicManager.songTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(musicManager.artistName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            musicButton("backward.fill", label: "Previous track", action: musicManager.previousTrack)
            musicButton(
                musicManager.isPlaying ? "pause.fill" : "play.fill",
                label: musicManager.isPlaying ? "Pause music" : "Play music",
                action: musicManager.togglePlay
            )
            musicButton("forward.fill", label: "Next track", action: musicManager.nextTrack)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { vm.isHoveringMediaPlayer = $0 }
        .onDisappear { vm.isHoveringMediaPlayer = false }
        .accessibilityIdentifier("focus-compact-music")
    }

    private func musicButton(
        _ icon: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct NotchScrollProtection: ViewModifier {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                vm.setScrollGestureSuppression(hovering, token: token)
            }
            .onDisappear {
                vm.setScrollGestureSuppression(false, token: token)
            }
    }
}

@ViewBuilder
private func emptyMessage(_ message: String) -> some View {
    Text(LocalizedStringKey(message))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding(8)
}
