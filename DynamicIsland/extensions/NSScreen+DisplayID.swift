import AppKit

extension NSScreen {
    /// Stable identity for a connected display; geometry must come from a current NSScreen.
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
    }
}
