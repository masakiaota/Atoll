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
        calendarManager.focusTimelineEvents
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
            await calendarManager.updateFocusTimelineEvents(for: selectedDate)
            await calendarManager.refreshIncompleteReminders()
        }
        .onChange(of: selectedDate) { _, date in
            Task {
                await calendarManager.updateCurrentDate(date)
                await calendarManager.updateFocusTimelineEvents(for: date)
            }
        }
    }

    @ViewBuilder
    private var dashboard: some View {
        VStack(spacing: 8) {
            if shouldShowLiveStrip {
                liveStrip
                    .frame(height: 54)
            }

            if let error = calendarManager.reminderMutationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
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

    var timedEvent: EventModel? {
        guard case .event(let event) = self, !event.isAllDay else { return nil }
        return event
    }

    var timePositionDate: Date? {
        switch self {
        case .event(let event): event.isAllDay ? nil : event.start
        case .reminder(let reminder): reminder.dueDate
        }
    }
}

private struct DayTimelineEntry: Identifiable {
    let item: DayTimelineItem
    let isUpcoming: Bool

    var id: String { item.id }
}

private struct FutureDayTimelineGroup: Identifiable {
    let day: Date
    let items: [DayTimelineItem]

    var id: Date { day }
}

private enum CurrentTimePlacement: Equatable {
    case hidden
    case between(Int)
    case inside(itemID: String, progress: CGFloat)

    var reservesVerticalSpace: Bool {
        if case .between = self { return true }
        return false
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

    private static let estimatedRowHeight: CGFloat = 44
    private static let rowSpacing: CGFloat = 2
    private static let currentTimeIndicatorHeight: CGFloat = 14
    private static let futureBoundarySpacerHeight: CGFloat = 18
    private static let futureGroupHeaderHeight: CGFloat = 18
    private static let relativeDayFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()
    private static let numericRelativeDayFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .full
        return formatter
    }()

    private var selectedDayInterval: DateInterval? {
        Calendar.current.dateInterval(of: .day, for: selectedDate)
    }

    private var selectedDayItems: [DayTimelineItem] {
        guard let interval = selectedDayInterval else { return [] }
        let eventItems = events
            .filter { $0.start < interval.end && $0.end > interval.start }
            .map(DayTimelineItem.event)
        let reminderItems = calendarManager.incompleteReminders.compactMap { reminder -> DayTimelineItem? in
            guard shouldShowReminder(reminder) else { return nil }
            return .reminder(reminder)
        }
        return sorted(eventItems + reminderItems)
    }

    private var upcomingItems: [DayTimelineItem] {
        guard let interval = selectedDayInterval,
              let lookaheadEnd = Calendar.current.date(
                byAdding: .day,
                value: CalendarManager.focusTimelineFetchDays,
                to: interval.start
              )
        else { return [] }

        let eventItems = events
            .filter { $0.start >= interval.end && $0.start < lookaheadEnd }
            .map(DayTimelineItem.event)
        let reminderItems = calendarManager.incompleteReminders.compactMap { reminder -> DayTimelineItem? in
            guard let dueDate = reminder.dueDate,
                  dueDate >= interval.end,
                  dueDate < lookaheadEnd
            else { return nil }
            return .reminder(reminder)
        }
        return sorted(eventItems + reminderItems)
    }

    private var upcomingGroups: [FutureDayTimelineGroup] {
        let calendar = Calendar.current
        return upcomingItems.reduce(into: []) { groups, item in
            let day = calendar.startOfDay(for: item.date)
            if let last = groups.last, calendar.isDate(last.day, inSameDayAs: day) {
                groups[groups.count - 1] = FutureDayTimelineGroup(
                    day: last.day,
                    items: last.items + [item]
                )
            } else {
                groups.append(FutureDayTimelineGroup(day: day, items: [item]))
            }
        }
    }

    private func sorted(_ items: [DayTimelineItem]) -> [DayTimelineItem] {
        items.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.sortPriority < rhs.sortPriority }
            return lhs.date < rhs.date
        }
    }

    private func currentTimePlacement(
        in items: [DayTimelineItem],
        now: Date
    ) -> CurrentTimePlacement {
        guard Calendar.current.isDate(selectedDate, inSameDayAs: now) else {
            return .hidden
        }

        let activeEvents = items.compactMap { item -> EventModel? in
            guard let event = item.timedEvent,
                  event.start <= now,
                  now < event.end
            else { return nil }
            return event
        }

        if activeEvents.count == 1, let event = activeEvents.first {
            let duration = event.end.timeIntervalSince(event.start)
            let progress = duration > 0
                ? CGFloat(now.timeIntervalSince(event.start) / duration)
                : 0
            return .inside(
                itemID: DayTimelineItem.event(event).id,
                progress: min(max(progress, 0), 1)
            )
        }

        if activeEvents.count > 1 {
            let activeIDs = Set(activeEvents.map { DayTimelineItem.event($0).id })
            let lastActiveIndex = items.lastIndex { activeIDs.contains($0.id) } ?? -1
            return .between(lastActiveIndex + 1)
        }

        if let nextIndex = items.firstIndex(where: {
            guard let positionDate = $0.timePositionDate else { return false }
            return positionDate > now
        }) {
            return .between(nextIndex)
        }
        return .between(items.count)
    }

    private func upcomingGroups(
        fitting height: CGFloat,
        selectedItemCount: Int,
        currentTimePlacement: CurrentTimePlacement
    ) -> [FutureDayTimelineGroup] {
        let rowExtent = Self.estimatedRowHeight + Self.rowSpacing
        var remainingHeight = height - CGFloat(selectedItemCount) * rowExtent
        if currentTimePlacement.reservesVerticalSpace {
            remainingHeight -= Self.currentTimeIndicatorHeight + Self.rowSpacing
        }

        let boundaryCost = Self.futureBoundarySpacerHeight + Self.rowSpacing * 2
        remainingHeight -= boundaryCost
        guard remainingHeight > 0 else { return [] }

        var fittedGroups: [FutureDayTimelineGroup] = []
        for group in upcomingGroups {
            let groupHeaderCost = Self.futureGroupHeaderHeight + Self.rowSpacing
            guard remainingHeight >= groupHeaderCost + rowExtent else { break }
            remainingHeight -= groupHeaderCost

            var fittedItems: [DayTimelineItem] = []
            for item in group.items {
                guard remainingHeight >= rowExtent else { break }
                fittedItems.append(item)
                remainingHeight -= rowExtent
            }

            guard !fittedItems.isEmpty else { break }
            fittedGroups.append(FutureDayTimelineGroup(day: group.day, items: fittedItems))
            if fittedItems.count < group.items.count { break }
        }
        return fittedGroups
    }

    private func shouldShowReminder(_ reminder: ReminderItem) -> Bool {
        guard let dueDate = reminder.dueDate else { return false }
        let calendar = Calendar.current
        if calendar.isDate(dueDate, inSameDayAs: selectedDate) {
            return true
        }
        return calendar.isDateInToday(selectedDate)
            && dueDate < calendar.startOfDay(for: selectedDate)
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

            timeline
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(NotchScrollProtection())
        .accessibilityIdentifier("focus-day-timeline")
    }

    private var timeline: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 60)) { context in
                timelineContent(fitting: geometry.size.height, now: context.date)
            }
        }
    }

    @ViewBuilder
    private func timelineContent(fitting height: CGFloat, now: Date) -> some View {
        let selectedItems = selectedDayItems
        let selectedEntries = selectedItems.map {
            DayTimelineEntry(item: $0, isUpcoming: false)
        }
        let currentTimePlacement = currentTimePlacement(in: selectedItems, now: now)
        let futureGroups = upcomingGroups(
            fitting: height,
            selectedItemCount: selectedItems.count,
            currentTimePlacement: currentTimePlacement
        )
        let hasScheduledContent = !selectedEntries.isEmpty || !futureGroups.isEmpty

        if !hasScheduledContent && isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasScheduledContent && !hasCalendarAccess {
            emptyMessage("Calendar access is not available.")
        } else if !hasScheduledContent && currentTimePlacement == .hidden {
            emptyMessage("No events or reminders")
        } else {
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(selectedEntries.enumerated()), id: \.element.id) { index, entry in
                        if currentTimePlacement == .between(index) {
                            currentTimeIndicator(now: now)
                        }
                        timelineRow(
                            entry,
                            currentTimeProgress: currentTimeProgress(
                                for: entry,
                                placement: currentTimePlacement
                            ),
                            now: now
                        )
                    }
                    if currentTimePlacement == .between(selectedEntries.count) {
                        currentTimeIndicator(now: now)
                    }

                    if !futureGroups.isEmpty {
                        Color.clear
                            .frame(height: Self.futureBoundarySpacerHeight)
                            .accessibilityHidden(true)
                        ForEach(futureGroups) { group in
                            futureGroupHeader(for: group.day)
                            ForEach(group.items) { item in
                                timelineRow(
                                    DayTimelineEntry(item: item, isUpcoming: true),
                                    now: now
                                )
                            }
                        }
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
    private func timelineRow(
        _ entry: DayTimelineEntry,
        currentTimeProgress: CGFloat? = nil,
        now: Date
    ) -> some View {
        switch entry.item {
        case .event(let event):
            Button {
                if let url = event.calendarAppURL() { openURL(url) }
            } label: {
                eventRow(event, isUpcoming: entry.isUpcoming)
                    .overlay {
                        if let currentTimeProgress {
                            currentTimeOverlay(now: now, progress: currentTimeProgress)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Open in Calendar")
            .accessibilityLabel("Open \(event.title) in Calendar")
        case .reminder(let reminder):
            ReminderRow(
                reminder: reminder,
                subtitle: reminderSubtitle(reminder, isUpcoming: entry.isUpcoming)
            )
            .opacity(entry.isUpcoming ? 0.82 : 1)
        }
    }

    private func currentTimeProgress(
        for entry: DayTimelineEntry,
        placement: CurrentTimePlacement
    ) -> CGFloat? {
        guard case .inside(let itemID, let progress) = placement,
              entry.id == itemID
        else { return nil }
        return progress
    }

    private func currentTimeOverlay(now: Date, progress: CGFloat) -> some View {
        GeometryReader { geometry in
            let centeredOffset = geometry.size.height * progress
                - Self.currentTimeIndicatorHeight / 2
            let offset = min(
                max(centeredOffset, 0),
                max(geometry.size.height - Self.currentTimeIndicatorHeight, 0)
            )
            currentTimeIndicator(now: now)
                .offset(y: offset)
        }
        .allowsHitTesting(false)
    }

    private func currentTimeIndicator(now: Date) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(Color.red)
                .frame(height: 1)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.red)
                .padding(.horizontal, 3)
                .background(Color.black.opacity(0.88), in: Capsule())
        }
        .frame(height: Self.currentTimeIndicatorHeight)
        .padding(.horizontal, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current time \(now.formatted(date: .omitted, time: .shortened))")
        .accessibilityIdentifier("focus-current-time-indicator")
    }

    private func futureGroupHeader(for day: Date) -> some View {
        Text(futureGroupTitle(for: day))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Self.futureGroupHeaderHeight, alignment: .leading)
            .padding(.horizontal, 9)
            .accessibilityAddTraits(.isHeader)
    }

    private func futureGroupTitle(for day: Date) -> String {
        "\(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
            + " · \(relativeDayDescription(for: day))"
    }

    private func eventRow(_ event: EventModel, isUpcoming: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(eventSubtitle(event))
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
        .opacity(isUpcoming ? 0.82 : 1)
    }

    private func eventSubtitle(_ event: EventModel) -> String {
        let time = event.isAllDay
            ? String(localized: "All day")
            : event.start.formatted(date: .omitted, time: .shortened)
        return time
    }

    private func reminderSubtitle(_ reminder: ReminderItem, isUpcoming: Bool) -> String {
        guard let dueDate = reminder.dueDate else { return reminder.calendar.title }
        if isUpcoming {
            let time = dueDate.formatted(date: .omitted, time: .shortened)
            return "\(time) · \(reminder.calendar.title)"
        }
        let dateStyle: Date.FormatStyle.DateStyle = Calendar.current.isDate(
            dueDate,
            inSameDayAs: selectedDate
        ) ? .omitted : .abbreviated
        return "\(dueDate.formatted(date: dateStyle, time: .shortened)) · \(reminder.calendar.title)"
    }

    private func relativeDayDescription(for date: Date) -> String {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let futureDay = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: selectedDay, to: futureDay).day ?? 0
        let formatter = calendar.isDateInToday(selectedDate)
            ? Self.relativeDayFormatter
            : Self.numericRelativeDayFormatter
        let relative = formatter.localizedString(
            from: DateComponents(day: dayOffset)
        )
        return relative
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
                            subtitle: reminder.calendar.title
                        )
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ReminderRow: View {
    let reminder: ReminderItem
    let subtitle: String

    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var focusTaskManager = FocusTaskManager.shared
    @State private var isCompleting = false
    @State private var isHoveringFocus = false
    @State private var isHoveringCompletion = false

    private var isFocused: Bool {
        focusTaskManager.selectedTask?.id == reminder.id
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: complete) {
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

            Button(action: toggleFocus) {
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

    private func toggleFocus() {
        if isFocused {
            focusTaskManager.clear()
        } else {
            focusTaskManager.select(reminder)
        }
    }

    private func complete() {
        guard !isCompleting else { return }
        isCompleting = true
        Task {
            if isFocused {
                await focusTaskManager.completeSelectedTask()
            } else {
                await calendarManager.setReminderCompleted(reminderID: reminder.id, completed: true)
            }
            isCompleting = false
        }
    }
}

private struct CompactMusicActivity: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject private var musicManager = MusicManager.shared
    @State private var sliderValue: Double = 0
    @State private var isDraggingSlider = false
    @State private var lastDragged = Date.distantPast

    private var canSeek: Bool {
        musicManager.songDuration.isFinite
            && musicManager.songDuration > 0
            && !musicManager.isLiveStream
    }

    private var isProgressTimelinePaused: Bool {
        !musicManager.isPlaying || musicManager.playbackRate <= 0
    }

    var body: some View {
        GeometryReader { geometry in
            let showsSeekBar = canSeek && geometry.size.width >= 560
            HStack(spacing: 12) {
                trackInfo
                    .frame(width: showsSeekBar ? 180 : nil, alignment: .leading)
                    .frame(maxWidth: showsSeekBar ? nil : .infinity, alignment: .leading)

                if showsSeekBar {
                    seekBar
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)
                }

                playbackControls
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { vm.isHoveringMediaPlayer = $0 }
        .onDisappear { vm.isHoveringMediaPlayer = false }
        .accessibilityIdentifier("focus-compact-music")
    }

    private var trackInfo: some View {
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
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 14) {
            musicButton("backward.fill", label: "Previous track", action: musicManager.previousTrack)
            playPauseButton
            musicButton("forward.fill", label: "Next track", action: musicManager.nextTrack)
        }
    }

    private var seekBar: some View {
        TimelineView(.animation(paused: isProgressTimelinePaused)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $isDraggingSlider,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying,
                isLiveStream: false,
                trackSignature: musicManager.trackSignature,
                onValueChange: { musicManager.seek(to: $0) },
                labelLayout: .inline,
                restingTrackHeight: 3,
                draggingTrackHeight: 5,
                sliderHitHeight: 24,
                showsThumbOnHover: true
            )
        }
        .frame(height: 24)
    }

    private var playPauseButton: some View {
        Button(action: musicManager.togglePlay) {
            Image(systemName: musicManager.isPlaying ? "pause.fill" : "play.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.black)
                .frame(width: 30, height: 30)
                .background(Color.white, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(musicManager.isPlaying ? "Pause music" : "Play music")
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
