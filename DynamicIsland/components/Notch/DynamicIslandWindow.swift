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
    weak var mouseRegion: NotchMouseRegionView? {
        didSet { updateMouseEventPassthrough() }
    }
    var suppressMouseEvents = false {
        didSet { updateMouseEventPassthrough() }
    }
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var mouseDownInNotch = false

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

    func updateMouseEventPassthrough() {
        if suppressMouseEvents {
            mouseDownInNotch = false
            ignoresMouseEvents = true
            return
        }
        // Keep receiving an in-progress drag that began inside Atoll.
        if mouseDownInNotch { return }
        ignoresMouseEvents = !(mouseRegion?.containsScreenPoint(NSEvent.mouseLocation) ?? false)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        contentView?.layoutSubtreeIfNeeded()
        updateMouseEventPassthrough()
    }

    override func close() {
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
