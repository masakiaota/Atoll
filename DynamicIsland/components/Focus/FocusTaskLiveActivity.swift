/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import SwiftUI

struct FocusTaskLiveActivity: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @ObservedObject private var manager = FocusTaskManager.shared

    let isNonNotchScreen: Bool

    var body: some View {
        if let task = manager.selectedTask {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if isNonNotchScreen {
                    nonNotchContent(task: task, date: context.date)
                } else {
                    physicalNotchContent(date: context.date)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func nonNotchContent(task: ReminderItem, date: Date) -> some View {
        HStack(spacing: 8) {
            FocusTaskIndicator(size: 18)
            Text(task.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            elapsedText(date)
        }
        .padding(.horizontal, 11)
        .frame(width: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)
        .background(Color.black)
    }

    private func physicalNotchContent(date: Date) -> some View {
        let height = vm.effectiveClosedNotchHeight

        return HStack(spacing: 0) {
            FocusTaskIndicator(size: min(20, max(14, height - 10)))
                .frame(width: height + 12, height: height)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: height)

            elapsedText(date)
                .padding(.horizontal, 9)
                .frame(height: height)
        }
        .frame(height: height)
    }

    private func elapsedText(_ date: Date) -> some View {
        Text(FocusTaskDurationFormatter.string(from: manager.elapsed(at: date)))
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .contentTransition(.numericText())
    }
}
