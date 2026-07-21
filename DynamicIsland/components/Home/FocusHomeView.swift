/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Defaults
import SwiftUI

struct FocusHomeView: View {
    private enum Detail {
        case music
        case camera
    }

    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var focusTaskManager = FocusTaskManager.shared
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var webcamManager = WebcamManager.shared

    @Default(.showMirror) private var showMirror
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.autoHideInactiveNotchMediaPlayer) private var autoHideInactiveNotchMediaPlayer

    @State private var selectedDate = Date()
    @State private var detail: Detail?

    let albumArtNamespace: Namespace.ID

    private var shouldShowMusicBar: Bool {
        showStandardMediaControls && (!autoHideInactiveNotchMediaPlayer || musicManager.hasActiveSession)
    }

    private var scheduleEvents: [EventModel] {
        calendarManager.events.filter { !$0.type.isReminder }
    }

    var body: some View {
        Group {
            switch detail {
            case .music:
                detailHeader(title: "Now Playing") {
                    MusicPlayerView(albumArtNamespace: albumArtNamespace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
            if calendarManager.calendarAuthorizationStatus == .notDetermined {
                await calendarManager.checkCalendarAuthorization()
            }
            if calendarManager.reminderAuthorizationStatus == .notDetermined {
                await calendarManager.checkReminderAuthorization()
            }
            await calendarManager.updateCurrentDate(selectedDate)
            await calendarManager.refreshIncompleteReminders()
        }
        .onChange(of: selectedDate) { _, date in
            Task { await calendarManager.updateCurrentDate(date) }
        }
    }

    private var dashboard: some View {
        VStack(spacing: 10) {
            FocusTaskCard()

            WheelPicker(
                selectedDate: $selectedDate,
                config: Config(past: 7, future: 14, steps: 1, spacing: 0, showsText: true, offset: 2)
            )
            .frame(height: 46)
            .environmentObject(vm)

            HStack(alignment: .top, spacing: 10) {
                HomePane(title: "Schedule", icon: "calendar") {
                    ScheduleList(events: scheduleEvents)
                }

                HomePane(title: "Reminders", icon: "checklist") {
                    ReminderSelectionList()
                }
            }
            .frame(maxHeight: .infinity)

            if shouldShowMusicBar || (showMirror && webcamManager.cameraAvailable) {
                HStack(spacing: 8) {
                    if shouldShowMusicBar {
                        CompactMusicBar {
                            withAnimation(.smooth(duration: 0.2)) { detail = .music }
                        }
                    }

                    if showMirror && webcamManager.cameraAvailable {
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { detail = .camera }
                        } label: {
                            Image(systemName: "camera.fill")
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open mirror")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

private struct FocusTaskCard: View {
    @ObservedObject private var manager = FocusTaskManager.shared

    var body: some View {
        HStack(spacing: 12) {
            FocusTaskIndicator()

            if let task = manager.selectedTask {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(task.calendar.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(FocusTaskDurationFormatter.string(from: manager.elapsed(at: context.date)))
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .contentTransition(.numericText())
                }

                Button {
                    if manager.isPaused {
                        manager.resume()
                    } else {
                        manager.pause()
                    }
                } label: {
                    Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.08), in: Circle())
                .accessibilityLabel(manager.isPaused ? "Resume task" : "Pause task")

                Button {
                    Task { await manager.completeSelectedTask() }
                } label: {
                    if manager.isCompleting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .frame(width: 26, height: 26)
                .buttonStyle(.plain)
                .background(Color.green.opacity(0.2), in: Circle())
                .disabled(manager.isCompleting)
                .accessibilityLabel("Complete reminder")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a reminder to focus")
                        .font(.headline)
                    Text("Select one from the list below")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let error = manager.completionError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .offset(y: 12)
            }
        }
        .accessibilityIdentifier("focus-task-card")
    }
}

struct FocusTaskIndicator: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 3)
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct HomePane<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            content
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ScheduleList: View {
    let events: [EventModel]

    var body: some View {
        if events.isEmpty {
            emptyMessage("No events")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(events) { event in
                        HStack(spacing: 8) {
                            Capsule()
                                .fill(Color(nsColor: event.calendar.color))
                                .frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ReminderSelectionList: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var focusTaskManager = FocusTaskManager.shared

    var body: some View {
        if calendarManager.incompleteReminders.isEmpty {
            switch calendarManager.reminderLoadState {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                emptyMessage(message)
            case .loaded:
                emptyMessage("No incomplete reminders")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(calendarManager.incompleteReminders) { reminder in
                        Button {
                            focusTaskManager.select(reminder)
                        } label: {
                            HStack(spacing: 8) {
                                if focusTaskManager.selectedTask?.id == reminder.id {
                                    FocusTaskIndicator(size: 16)
                                } else {
                                    Circle()
                                        .stroke(Color(nsColor: reminder.calendar.color), lineWidth: 1.5)
                                        .frame(width: 16, height: 16)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reminder.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text(reminderSubtitle(reminder))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
            .accessibilityIdentifier("reminder-selection-list")
        }
    }

    private func reminderSubtitle(_ reminder: ReminderItem) -> String {
        guard let dueDate = reminder.dueDate else { return reminder.calendar.title }
        return "\(reminder.calendar.title) · \(dueDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct CompactMusicBar: View {
    @ObservedObject private var musicManager = MusicManager.shared
    let openDetails: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: openDetails) {
                HStack(spacing: 9) {
                    Image(nsImage: musicManager.albumArt)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(musicManager.songTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(musicManager.artistName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            musicButton("backward.fill", action: musicManager.previousTrack)
            musicButton(musicManager.isPlaying ? "pause.fill" : "play.fill", action: musicManager.togglePlay)
            musicButton("forward.fill", action: musicManager.nextTrack)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func musicButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
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
