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

import Combine
import Defaults
import SwiftUI

@MainActor
class DynamicIslandViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: DynamicIslandAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed
    @Published private(set) var isMenuBarExpanded = false
    @Published private(set) var availableLeftWidth: CGFloat? = nil

    /// Set while Mission Control is showing; the content tucks up out of sight.
    @Published var isTuckedForMissionControl = false
    @Published private(set) var isMenuBarColliding = false
    @Published private(set) var isRetractedForMenuBar = false
    private var collisionWidth: CGFloat?
    /// True once the tuck-away motion has finished and the window is the 3pt line.
    private(set) var usesMenuBarLineWindow = false
    private var lastCollisionNotchState: NotchState = .closed
    private var closingSettlesAt = Date.distantPast
    var menuBarCollisionWidth: CGFloat { collisionWidth ?? closedNotchSize.width }
    private var lastCollisionLogState: String?
    private static let collisionLogQueue = DispatchQueue(label: "dev.atoll.menu-bar-collision-log")

    /// While retracted the window is only a 3pt line, so the pointer is polled
    /// instead: pushing it against the top edge brings the notch back down, and
    /// it stays down (overlapping menu bar items) until the pointer leaves it.
    private var menuBarHoverReveal = false
    private var menuBarHoverRevealTimer: Timer?
    private var menuBarHoverLeftAt: Date?
    private var menuBarHoverInsideSince: Date?

    private func syncMenuBarHoverRevealTimer() {
        let needed = isMenuBarColliding || menuBarHoverReveal
        if needed, menuBarHoverRevealTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollMenuBarHoverReveal() }
            }
            RunLoop.main.add(timer, forMode: .common)
            menuBarHoverRevealTimer = timer
        } else if !needed, let timer = menuBarHoverRevealTimer {
            timer.invalidate()
            menuBarHoverRevealTimer = nil
            menuBarHoverLeftAt = nil
        }
    }

    private func pollMenuBarHoverReveal() {
        // The lock screen closes the notch itself; never reveal or reopen it there.
        guard !LockScreenManager.shared.isLocked else { return }
        guard let display = NSScreen.screens.first(where: { $0.localizedName == screen }) ?? NSScreen.main else { return }
        let location = NSEvent.mouseLocation
        let width = collisionWidth ?? getClosedNotchSize(screen: display.localizedName).width
        let height = closedNotchSize.height
        if !menuBarHoverReveal {
            let edge = CGRect(x: display.frame.midX - width / 2 - 8, y: display.frame.maxY - 8, width: width + 16, height: 10)
            guard isMenuBarColliding, notchState == .closed, edge.contains(location) else { return }
            menuBarHoverReveal = true
            menuBarHoverLeftAt = nil
            menuBarHoverInsideSince = nil
            updateMenuBarCollision()
            return
        }
        let hold = CGRect(x: display.frame.midX - width / 2 - 12, y: display.frame.maxY - height - 10,
                          width: width + 24, height: height + 12)
        if notchState != .closed || hold.contains(location) {
            menuBarHoverLeftAt = nil
            // The view's own hover tracking may miss a pointer that was already
            // inside when the window grew back, so honor hover-to-open here too.
            let sneak = coordinator.sneakPeek
            let sneakVisible = sneak.show && (!Defaults[.showOnAllDisplays]
                || sneak.targetScreenName == nil || sneak.targetScreenName == (screen ?? coordinator.selectedScreen))
            if sneakVisible {
                // Same rule as ContentView.handleHover: a HUD is not interrupted by hover-open.
                if menuBarHoverInsideSince != .distantFuture { menuBarHoverInsideSince = nil }
            } else if notchState == .closed, Defaults[.openNotchOnHover], !coordinator.isHoverOpenSuppressed {
                let since = menuBarHoverInsideSince ?? Date()
                menuBarHoverInsideSince = since
                if Date().timeIntervalSince(since) >= max(Defaults[.minimumHoverDuration], 0.2) {
                    menuBarHoverInsideSince = .distantFuture // once per reveal
                    open()
                }
            }
        } else if let left = menuBarHoverLeftAt {
            guard Date().timeIntervalSince(left) > 0.35 else { return }
            menuBarHoverReveal = false
            menuBarHoverLeftAt = nil
            updateMenuBarCollision()
        } else {
            menuBarHoverLeftAt = Date()
        }
    }

    func updateMenuBarCollisionPresentation(width: CGFloat) {
        if notchState == .closed { collisionWidth = width }
        updateMenuBarCollision()
    }

    private func updateMenuBarCollision() {
        guard !AppRuntimeEnvironment.isUITesting,
              let display = NSScreen.screens.first(where: { $0.localizedName == screen }) ?? NSScreen.main else { return }
        guard display.physicalNotchFrame == nil else {
            if isRetractedForMenuBar || usesMenuBarLineWindow {
                isRetractedForMenuBar = false
                usesMenuBarLineWindow = false
                AppDelegate.shared?.refreshMenuBarPresentation()
            }
            if isMenuBarColliding { isMenuBarColliding = false }
            collisionWidth = nil
            menuBarHoverReveal = false
            syncMenuBarHoverRevealTimer()
            return
        }
        // Match ContentView's screen-specific sneakPeek and expandingView predicates.
        // This also runs while an inactive display uses its lightweight placeholder.
        let currentScreen = screen ?? coordinator.selectedScreen
        let sneak = coordinator.sneakPeek
        let sneakVisible = sneak.show && (!Defaults[.showOnAllDisplays]
            || sneak.targetScreenName == nil || sneak.targetScreenName == currentScreen)
        var expansionVisible = coordinator.expandingView.show
        if coordinator.expandingView.type == .battery {
            let battery = BatteryStatusViewModel.shared
            expansionVisible = expansionVisible && Defaults[.showPowerStatusNotifications]
                && battery.activeTemporaryHUDKind != nil
                && (Defaults[.showOnAllDisplays] || battery.activeTemporaryHUDTargetScreenName == nil
                    || battery.activeTemporaryHUDTargetScreenName == currentScreen)
        }
        let collisionTemporaryReveal = sneakVisible || expansionVisible
        let enabled = Defaults[.retractVirtualNotchOnMenuBarCollision]
        let snapshot = MenuBarOverflowMonitor.shared.collisionSnapshots[display.localizedName]
        let width = collisionWidth ?? getClosedNotchSize(screen: display.localizedName).width
        let notch = CGRect(x: display.frame.midX - width / 2, y: display.frame.maxY - closedNotchSize.height,
                           width: width, height: closedNotchSize.height)
        if !enabled {
            if isMenuBarColliding { isMenuBarColliding = false }
        } else if let snapshot {
            let collision = MenuBarCollision.shouldRetract(
                items: snapshot.menuFrames + snapshot.iconFrames, notch: notch, currentlyRetracted: isMenuBarColliding)
            if isMenuBarColliding != collision { isMenuBarColliding = collision }
        }
        if !isMenuBarColliding { menuBarHoverReveal = false }
        syncMenuBarHoverRevealTimer()
        // A notch hidden for fullscreen stays fully hidden; do not leave the line behind.
        var retract = isMenuBarColliding && notchState == .closed && !hideOnClosed
            && !collisionTemporaryReveal && !menuBarHoverReveal
        // Let an open notch finish closing before it tucks away, so the two
        // motions read as one sequence instead of fighting each other.
        if notchState != lastCollisionNotchState {
            if notchState == .closed, lastCollisionNotchState == .open {
                closingSettlesAt = Date().addingTimeInterval(0.34)
            }
            lastCollisionNotchState = notchState
        }
        if retract, !isRetractedForMenuBar {
            let remaining = closingSettlesAt.timeIntervalSinceNow
            if remaining > 0 {
                retract = false
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.01) { [weak self] in
                    self?.updateMenuBarCollision()
                }
            }
        }
        let changed = isRetractedForMenuBar != retract
        if changed {
            if retract {
                // Slide up first; shrink the window to the line only once the
                // notch is out of sight, so the window never clips the motion.
                withAnimation(NotchTuckMotion.animation(hiding: true)) { isRetractedForMenuBar = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + NotchTuckMotion.hideDuration + 0.02) { [weak self] in
                    guard let self, self.isRetractedForMenuBar, !self.usesMenuBarLineWindow else { return }
                    self.usesMenuBarLineWindow = true
                    AppDelegate.shared?.refreshMenuBarPresentation()
                }
            } else {
                // Give the notch its full window back before it slides down.
                usesMenuBarLineWindow = false
                AppDelegate.shared?.refreshMenuBarPresentation()
                withAnimation(NotchTuckMotion.animation(hiding: false)) { isRetractedForMenuBar = false }
            }
        }
        let logState = "\(isMenuBarColliding),\(retract),\(collisionTemporaryReveal),\(menuBarHoverReveal),\(snapshot?.isActiveScreen.description ?? "unknown")"
        if snapshot != nil, lastCollisionLogState != logState, UserDefaults.standard.bool(forKey: "menuBarCollisionDebugLog") {
            lastCollisionLogState = logState
            let overlapping = (snapshot?.menuFrames ?? []) + (snapshot?.iconFrames ?? [])
            var ranges: [String] = []
            let left = notch.minX - 4
            let right = notch.maxX + 4
            for item in overlapping where item.maxX > left && item.minX < right {
                ranges.append("\(item.minX)...\(item.maxX)")
            }
            let overlap = ranges.joined(separator: ",")
            let menu = snapshot?.menuFrames.map(\.maxX).max().map { String(describing: $0) } ?? "unknown"
            let icons = snapshot?.iconFrames.map(\.minX).min().map { String(describing: $0) } ?? "unknown"
            let line = "\(Date().ISO8601Format()) screen=\(display.localizedName) notch=\(notch.minX)...\(notch.maxX) menuRight=\(menu) iconLeft=\(icons) overlaps=\(overlap) retracted=\(retract) temporary=\(collisionTemporaryReveal) hover=\(menuBarHoverReveal) active=\(snapshot?.isActiveScreen.description ?? "unknown")\n"
            Self.collisionLogQueue.async {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Atoll-menu-bar-collision.log")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
        }
    }

    var physicalNotchFrame: CGRect? {
        (NSScreen.screens.first { $0.localizedName == screen } ?? NSScreen.main)?.physicalNotchFrame
    }

    var usesLeftSideLayout: Bool {
        notchState == .closed && physicalNotchFrame != nil
    }

    @Published var dragDetectorTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []

    /// Teardown hook ContentView registers in `onAppear`; the window-cleanup path
    /// invokes it before closing the panel since `.onDisappear` is unreliable for
    /// borderless panels, preventing leaked hover-polling Tasks from accumulating.
    var onViewTeardown: (() -> Void)?
    
    @Published var hideOnClosed: Bool = true
    @Published var isHoveringCalendar: Bool = false
    @Published var isBatteryPopoverActive: Bool = false
    @Published var isClipboardPopoverActive: Bool = false
    @Published var isColorPickerPopoverActive: Bool = false
    @Published var isStatsPopoverActive: Bool = false
    @Published var isReminderPopoverActive: Bool = false
    @Published var isMediaOutputPopoverActive: Bool = false
    @Published var isTimerPopoverActive: Bool = false
    @Published var shouldRecheckHover: Bool = false
    @Published var isScrollGestureActive: Bool = false
    @Published var isHoveringMediaPlayer: Bool = false
    private var scrollGestureSuppressionTokens: Set<UUID> = []
    @Published private(set) var isAutoCloseSuppressed: Bool = false
    private var autoCloseSuppressionTokens: Set<UUID> = []
    private let clipboardFocusWindow: TimeInterval = 10

    func setScrollGestureSuppression(_ active: Bool, token: UUID) {
        if active {
            let inserted = scrollGestureSuppressionTokens.insert(token).inserted
            if inserted {
                isScrollGestureActive = true
            }
        } else {
            if scrollGestureSuppressionTokens.remove(token) != nil {
                isScrollGestureActive = !scrollGestureSuppressionTokens.isEmpty
            }
        }
    }

    private func resetScrollGestureSuppression() {
        scrollGestureSuppressionTokens.removeAll()
        isScrollGestureActive = false
    }

    func setAutoCloseSuppression(_ active: Bool, token: UUID) {
        if active {
            let inserted = autoCloseSuppressionTokens.insert(token).inserted
            if inserted {
                isAutoCloseSuppressed = true
            }
        } else if autoCloseSuppressionTokens.remove(token) != nil {
            isAutoCloseSuppressed = !autoCloseSuppressionTokens.isEmpty
        }
    }

    private func resetAutoCloseSuppression() {
        autoCloseSuppressionTokens.removeAll()
        isAutoCloseSuppressed = false
    }

    private func focusClipboardTabIfNeeded() {
        guard !Defaults[.enableMinimalisticUI] else { return }
        guard Defaults[.enableClipboardManager] else { return }
        guard Defaults[.clipboardDisplayMode] == .separateTab else { return }
        guard let lastCopyDate = ClipboardManager.shared.lastCopiedItemDate else { return }
        guard Date().timeIntervalSince(lastCopyDate) <= clipboardFocusWindow else { return }
        guard coordinator.currentView != .notes else { return }
        withAnimation(.smooth) {
            coordinator.currentView = .notes
        }
    }
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false

    @Published var screen: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    @MainActor
    deinit {
        destroy()
    }

    func destroy() {
        onViewTeardown?()
        onViewTeardown = nil
        // The run loop retains the timer; release it with the view model.
        menuBarHoverRevealTimer?.invalidate()
        menuBarHoverRevealTimer = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screen: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screen = screen
        notchSize = getClosedNotchSize(screen: screen)
        closedNotchSize = notchSize

        let menuBar = MenuBarOverflowMonitor.shared
        coordinator.$sneakPeek.combineLatest(coordinator.$expandingView)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.physicalNotchFrame == nil else { return }
                self?.updateMenuBarCollision()
            }
            .store(in: &cancellables)
        menuBar.$collisionSnapshots.combineLatest($screen, $notchState, $hideOnClosed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarCollision() }
            .store(in: &cancellables)
        Defaults.publisher(.retractVirtualNotchOnMenuBarCollision)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarCollision() }
            .store(in: &cancellables)
        menuBar.$expandedScreens.combineLatest($screen)
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded, screenName in
                guard let self else { return }
                let isExpanded = expanded.contains(screenName ?? NSScreen.main?.localizedName ?? "")
                guard self.isMenuBarExpanded != isExpanded else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.isMenuBarExpanded = isExpanded
                    if isExpanded {
                        self.notchState = .closed
                        self.notchSize = self.physicalNotchFrame?.size ?? self.closedNotchSize
                        self.resetScrollGestureSuppression()
                        self.resetAutoCloseSuppression()
                        self.isHoveringMediaPlayer = false
                    } else {
                        self.notchSize = self.closedNotchSize
                    }
                }
                if isExpanded {
                    MusicControlWindowManager.shared.hide()
                }
                AppDelegate.shared?.refreshMenuBarPresentation()
            }
            .store(in: &cancellables)
        menuBar.$availableLeftWidths.combineLatest($screen)
            .receive(on: RunLoop.main)
            .sink { [weak self] widths, screenName in
                self?.availableLeftWidth = widths[screenName ?? NSScreen.main?.localizedName ?? ""]
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($dropZoneTargeting, $dragDetectorTargeting)
            .map { value1, value2 in
                value1 || value2
            }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()

        ReminderLiveActivityManager.shared.$activeWindowReminders
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchState == .open else { return }
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.smooth) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        // Observe settings + lyrics changes to dynamically resize the notch
        let enableLyricsPublisher = Defaults.publisher(.enableLyrics).map { $0.newValue }

        enableLyricsPublisher
            .combineLatest(MusicManager.shared.$currentLyrics)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard Defaults[.enableMinimalisticUI] else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchState == .open else { return }
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.smooth) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        TimerManager.shared.$activeSource
            .combineLatest(TimerManager.shared.$isTimerActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.handleMinimalisticTimerHeightChange()
            }
            .store(in: &cancellables)

        coordinator.$statsSecondRowExpansion
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: false,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        coordinator.$notesLayoutState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)

        Defaults.publisher(.openNotchWidth, options: [])
            .map { $0.newValue }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                guard !Defaults[.enableMinimalisticUI] else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }
                withAnimation(.smooth) {
                    self.notchSize = updatedTarget
                }
                if let delegate = AppDelegate.shared {
                    delegate.ensureWindowSize(
                        addShadowPadding(to: updatedTarget, isMinimalistic: false),
                        animated: true,
                        force: false
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func handleMinimalisticTimerHeightChange() {
        guard Defaults[.enableMinimalisticUI] else { return }
        guard notchState == .open else { return }
        let updatedTarget = calculateDynamicNotchSize()
        guard notchSize != updatedTarget else { return }
        withAnimation(.smooth) {
            notchSize = updatedTarget
        }
        if let delegate = AppDelegate.shared {
            delegate.ensureWindowSize(
                addShadowPadding(to: updatedTarget, isMinimalistic: Defaults[.enableMinimalisticUI]),
                animated: true,
                force: false
            )
        }
    }
    
    private func setupDetectorObserver() {
        // 1) Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.enableFullscreenMediaDetection)
            .map(\.newValue)

        // 2) For each non‑nil screen name, map to a Bool publisher for that screen's status
        let statusPublisher = $screen
            .compactMap { $0 }
            .removeDuplicates()
            .map { screenName in
                self.detector.$fullscreenStatus
                    .map { $0[screenName] ?? false }
                    .removeDuplicates()
            }
            .switchToLatest()

        // 3) Combine enabled & status, animate only on changes
        Publishers.CombineLatest(statusPublisher, enabledPublisher)
            .map { status, enabled in enabled && status }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(NotchTuckMotion.animation(hiding: shouldHide)) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }
    
    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = NSScreen.screens.first { $0.localizedName == screen }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard !isMenuBarExpanded else { return false }
        let screenFrame = getScreenFrame(screen)
        if let frame = screenFrame {
            
            if isRetractedForMenuBar {
                let width = getClosedNotchSize(screen: screen).width
                return CGRect(x: frame.midX - width / 2, y: frame.maxY - 3, width: width, height: 3).contains(position)
            }
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            
            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        
        return false
    }

    func open() {
        guard !isMenuBarExpanded else { return }
        let targetSize = calculateDynamicNotchSize()

        let applyWindowResize: () -> Void = {
            guard let delegate = AppDelegate.shared else { return }
            delegate.ensureWindowSize(
                addShadowPadding(to: targetSize, isMinimalistic: Defaults[.enableMinimalisticUI]),
                animated: false,
                force: true
            )
        }

        if isRetractedForMenuBar {
            notchState = .open
            updateMenuBarCollision()
        }
        if Thread.isMainThread {
            applyWindowResize()
        } else {
            DispatchQueue.main.async(execute: applyWindowResize)
        }

        notchSize = targetSize
        notchState = .open

        // Force music information update when notch is opened
        MusicManager.shared.forceUpdate()
        focusClipboardTabIfNeeded()
    }
    
    private func calculateDynamicNotchSize() -> CGSize {
        let baseSize = resolvedOpenNotchSize(
            for: coordinator.currentView,
            isDynamicIslandMode: shouldUseDynamicIslandMode(for: screen)
        )
        var adjustedSize = baseSize

        if coordinator.currentView == .notes || coordinator.currentView == .clipboard {
            let preferred = coordinator.notesLayoutState.preferredHeight
            adjustedSize.height = max(adjustedSize.height, preferred)
            return adjustedSize
        }

        return statsAdjustedNotchSize(
            from: adjustedSize,
            isStatsTabActive: coordinator.currentView == .stats,
            secondRowProgress: coordinator.statsSecondRowExpansion
        )
    }

    func close() {
        let targetSize = getClosedNotchSize(screen: screen)
        notchSize = targetSize
        closedNotchSize = targetSize
        notchState = .closed
        resetScrollGestureSuppression()
        isHoveringMediaPlayer = false
        resetAutoCloseSuppression()

        // Set the current view to shelf if it contains files and the user enables openShelfByDefault
        // Otherwise, if the user has not enabled openLastShelfByDefault, set the view to home
        if !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] && !Defaults[.enableMinimalisticUI] {
            coordinator.currentView = .shelf
        } else if !coordinator.openLastTabByDefault {
            coordinator.currentView = .home
        }
    }

    func closeForLockScreen() {
        let targetSize = getClosedNotchSize(screen: screen)
        withAnimation(.none) {
            notchSize = targetSize
            closedNotchSize = targetSize
            notchState = .closed
            resetScrollGestureSuppression()
            isHoveringMediaPlayer = false
            resetAutoCloseSuppression()
        }
    }

    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "OK")
                alert.runModal()

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }
}
