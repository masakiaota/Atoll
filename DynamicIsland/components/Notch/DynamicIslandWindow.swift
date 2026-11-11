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

import Cocoa
import SwiftUI

class DynamicIslandWindow: NSPanel {
    var onPointerScreenChange: ((Bool) -> Void)?
    private var isPointerOnScreen: Bool?

    weak var mouseRegion: NotchMouseRegionView? {
        didSet { updateMouseEventPassthrough() }
    }
    var suppressMouseEvents = false {
        didSet { updateMouseEventPassthrough() }
    }
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var mouseDownInNotch = false

    /// "Show Desktop" sweeps a transient window away with ordinary windows, and
    /// macOS reports that neither to AppKit nor through Dock. The notch belongs
    /// to the screen edge, so compare where the window server really draws it
    /// with where Atoll placed it, and fade it out while it is displaced.
    private var displacementTimer: Timer?
    private var lastDisplacementCheck: TimeInterval = 0
    private var isDisplacedBySystem = false {
        didSet {
            guard oldValue != isDisplacedBySystem else { return }
            super.alphaValue = isDisplacedBySystem ? 0 : requestedAlpha
            updateMouseEventPassthrough()
        }
    }
    private var requestedAlpha: CGFloat = 1
    override var alphaValue: CGFloat {
        get { requestedAlpha }
        set {
            requestedAlpha = newValue
            super.alphaValue = isDisplacedBySystem ? 0 : newValue
        }
    }

    private func checkSystemDisplacement(throttled: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if throttled, now - lastDisplacementCheck < 0.05 { return }
        lastDisplacementCheck = now
        guard windowNumber > 0, isVisible,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let actual = CGRect(dictionaryRepresentation: dictionary),
              let top = NSScreen.screens.first?.frame.maxY else { return }
        // Far beyond any frame animation of our own; Show Desktop moves it by most of a screen.
        let displaced = abs(actual.minX - frame.minX) > 30 || abs(actual.minY - (top - frame.maxY)) > 30
        if isDisplacedBySystem != displaced { isDisplacedBySystem = displaced }
    }

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .ignoresCycle,
            .transient,
        ]
        
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true

        // A transparent NSHostingView still occupies a native window. Decide
        // passthrough before a click, using the actual SwiftUI surface, not the
        // much larger canvas reserved for opening and shadows.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                             .rightMouseDragged, .otherMouseDragged,
                                             .leftMouseUp, .rightMouseUp, .otherMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.trackMouseButton(event)
            self?.updateMouseEventPassthrough()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.trackMouseButton(event)
            self?.updateMouseEventPassthrough()
        }

        ScreenCaptureVisibilityManager.shared.register(self, scope: .entireInterface)
        // Mouse events give an immediate check for free; the timer covers
        // keyboard-triggered Show Desktop while the pointer rests.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSystemDisplacement(throttled: false)
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        displacementTimer = timer
    }

    private func trackMouseButton(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            mouseDownInNotch = event.window === self && !ignoresMouseEvents
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            mouseDownInNotch = false
        default:
            break
        }
    }

    func updateMouseEventPassthrough(at location: NSPoint = NSEvent.mouseLocation) {
        checkSystemDisplacement(throttled: true)
        // Reuse the existing native mouse monitors instead of adding a timer
        // or one more pair of global/local monitors per display.
        if onPointerScreenChange != nil, let screen {
            let containsPointer = screen.frame.contains(location)
            if isPointerOnScreen != containsPointer {
                isPointerOnScreen = containsPointer
                onPointerScreenChange?(containsPointer)
            }
        }
        if suppressMouseEvents || isDisplacedBySystem {
            mouseDownInNotch = false
            ignoresMouseEvents = true
            return
        }
        // Keep receiving an in-progress drag that began inside Atoll.
        if mouseDownInNotch { return }
        ignoresMouseEvents = !(mouseRegion?.containsScreenPoint(location) ?? false)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        contentView?.layoutSubtreeIfNeeded()
        updateMouseEventPassthrough()
    }

    override func close() {
        onPointerScreenChange = nil
        displacementTimer?.invalidate()
        displacementTimer = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        super.close()
    }
    
    override var canBecomeKey: Bool {
        true
    }
    
    override var canBecomeMain: Bool {
        true
    }

}

/// Measures the clipped surface before shadow padding is applied. It never
/// handles a SwiftUI gesture itself; it only supplies the native input boundary.
struct NotchMouseRegion: NSViewRepresentable {
    var shape: AnyShape

    func makeNSView(context: Context) -> NotchMouseRegionView {
        NotchMouseRegionView()
    }

    func updateNSView(_ view: NotchMouseRegionView, context: Context) {
        view.shape = shape
        view.needsLayout = true
    }
}

final class NotchMouseRegionView: NSView {
    var shape = AnyShape(Rectangle())
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? DynamicIslandWindow)?.mouseRegion = self
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let panel = window as? DynamicIslandWindow, panel.mouseRegion === self {
            panel.mouseRegion = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        (window as? DynamicIslandWindow)?.updateMouseEventPassthrough()
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return bounds.contains(local) && shape.path(in: bounds).contains(local)
    }
}
