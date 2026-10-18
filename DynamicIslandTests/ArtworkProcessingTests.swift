import AppKit
import Combine
import os

@MainActor
final class MusicManager {
    static let shared = MusicManager()
    @Published var albumArt = NSImage()
    @Published var songTitle = "Track"
    @Published var artistName = "Artist"
    var videoArtworkURL: URL?
    var bundleIdentifier: String?
    var hasActiveSession = true
}

enum SpotifyController {
    static let bundleIdentifier = "com.spotify.client"
}

@MainActor
final class LockScreenManager {
    static let shared = LockScreenManager()
    var isLocked = false
}

@MainActor
final class LockScreenPanelManager {
    static let shared = LockScreenPanelManager()
    func applyOffsetAdjustment(animated: Bool) {}
}

// The runner inserts the real lifecycle, Combine subscriptions, encoding,
// persistence and presentation decisions. System wallpaper/video/UI services
// are inert, and all generated files stay in this test's temporary directory.
@MainActor
final class FullScreenArtworkWindowManager {
    enum ArtworkOverlayMode { case none, spotifyFallback }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var blurredCount = 0

    func observeVideoArtworkChanges() {}
    func observePanelFrameChanges() {}
    func observeArtworkLayoutOverCanvasPreference() {}
    func observeLyricsChanges() {}
    func observeLyricsPreference() {}
    func observePlaybackStateChanges() {}
    func observeAppTermination() {}
    func resumeWallpaperAgentIfNeeded() {}
    func removeFallbackRightClickMonitor() {}
    func hideVideoWindow() {}
    func hideArtworkOverlay() {}
    func hideLyricsOverlay() {}
    func hideWallpaperTransition() {}
    func hideClickReceiver() {}
    func restoreWallpaper() {}
    func backupWallpaperConfig() {}
    func restartWallpaperAgent() {}
    func installFallbackRightClickMonitorIfNeeded() {}
    func updateLyricsOverlayIfNeeded(on screen: NSScreen) {}
    func showClickReceiver(on screen: NSScreen) {}
    func showWallpaperTransition(on screen: NSScreen, imageURL: URL) {}
    func showArtworkOverlay(on screen: NSScreen, artwork: NSImage, mode: ArtworkOverlayMode) {}
    func scheduleLiveWallpaperPreparation(for videoURL: URL?, artwork: NSImage, identifier: String) {}
    func scheduleWallpaperTransitionHide(after delay: Duration) {}
    func applyArtworkToPlist(imageURL: URL) -> Bool { true }
    func shouldUseSpotifyFallbackLayout(videoURL: URL?) -> Bool {
        MusicManager.shared.bundleIdentifier == SpotifyController.bundleIdentifier
    }
    func artworkCacheFileURL(for fingerprint: String) -> URL {
        directory.appendingPathComponent("\(fingerprint).png")
    }
    func blurredWallpaperFileURL(for artwork: NSImage, fingerprint: String, screen: NSScreen) -> URL? {
        blurredCount += 1
        return directory.appendingPathComponent("blurred.png")
    }

    // ARTWORK_MANAGER_METHODS
}

// Counting TIFF requests observes real PNG conversions without replacing the
// encoder. Production processing in these tests runs on the main actor.
private final class TestImage: NSImage, @unchecked Sendable {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    var encodings: Int { counter.withLock { $0 } }
    override var tiffRepresentation: Data? {
        counter.withLock { $0 += 1 }
        return super.tiffRepresentation
    }
}

@main
@MainActor
private struct ArtworkProcessingTests {
    static func flush(_ seconds: TimeInterval = 0.3) {
        autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
    }

    static func image(_ red: UInt8) -> TestImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 64, bitsPerPixel: 32)!
        let bytes = bitmap.bitmapData!
        for offset in stride(from: 0, to: 16 * 16 * 4, by: 4) {
            bytes[offset] = red
            bytes[offset + 1] = 32
            bytes[offset + 2] = 64
            bytes[offset + 3] = 255
        }
        let image = TestImage(size: CGSize(width: 16, height: 16))
        image.addRepresentation(bitmap)
        return image
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(NSScreen.main != nil, "The artwork tests require a desktop screen")
        let music = MusicManager.shared
        let first = image(10)
        music.albumArt = first
        let manager = FullScreenArtworkWindowManager()
        try FileManager.default.createDirectory(at: manager.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: manager.directory) }

        flush()
        precondition(first.encodings == 0 && manager.artworkChangeCancellable == nil,
                     "An idle manager must neither encode nor subscribe to artwork")
        let initialFiles = try FileManager.default.contentsOfDirectory(atPath: manager.directory.path)
        precondition(initialFiles.isEmpty,
                     "Hidden artwork must not create cache files")

        manager.show(artwork: first)
        flush()
        precondition(manager.isShowing && manager.artworkChangeCancellable != nil)
        precondition(first.encodings == 1, "First show must encode once for both identity and persistence")
        precondition(manager.blurredCount == 0, "Plain artwork must not generate a screen-sized blur")
        let firstURL = manager.cachedArtworkPNG!
        let png = try Data(contentsOf: firstURL)
        precondition(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "The cached file must be PNG")

        let intermediate = image(20)
        let latest = image(30)
        music.albumArt = intermediate
        music.albumArt = latest
        flush()
        precondition(intermediate.encodings == 0 && latest.encodings == 1,
                     "Visible artwork changes must coalesce and prepare only the current image")
        precondition(manager.cachedArtworkPNG != firstURL)

        let pending = image(40)
        let hidden = image(50)
        music.albumArt = pending
        manager.hide()
        precondition(manager.artworkChangeCancellable == nil && manager.trackChangeCancellable == nil)
        music.albumArt = hidden
        manager.show(artwork: hidden)
        flush()
        precondition(pending.encodings == 0 && hidden.encodings == 1,
                     "Hide must discard pending updates, and reopen must prepare the latest image once")

        manager.hide()
        let idle = image(60)
        music.albumArt = idle
        let fileCount = try FileManager.default.contentsOfDirectory(atPath: manager.directory.path).count
        flush()
        precondition(idle.encodings == 0)
        let idleFiles = try FileManager.default.contentsOfDirectory(atPath: manager.directory.path)
        precondition(idleFiles.count == fileCount)

        manager.show(artwork: idle)
        manager.scheduleDeferredTrackRefresh(expectedTitle: music.songTitle, expectedArtist: music.artistName)
        manager.hide()
        manager.show(artwork: idle)
        flush(0.85)
        precondition(idle.encodings == 2, "Cancelled refreshes must not run after a quick reopen")

        let cached = manager.cachedArtworkPNG!
        try FileManager.default.removeItem(at: cached)
        let regenerated = manager.persistedArtworkFile(for: idle)
        precondition(regenerated?.url == cached && FileManager.default.fileExists(atPath: cached.path),
                     "A missing disk cache must be regenerated")
        precondition(idle.encodings == 3, "Cache regeneration must also reuse one PNG conversion")

        manager.hide()
        music.bundleIdentifier = SpotifyController.bundleIdentifier
        manager.show(artwork: idle)
        precondition(manager.blurredCount == 1, "Spotify's static fallback still requires a blur")
        manager.hide()
        music.bundleIdentifier = nil
        manager.show(artwork: idle, videoURL: URL(fileURLWithPath: "/test-canvas.mov"), allowLiveWallpaper: true)
        precondition(manager.blurredCount == 2 && manager.pendingFallbackStaticURL != nil,
                     "Canvas presentation must retain its blurred fallback")

        manager.hide()
        try FileManager.default.removeItem(at: manager.directory)
        try Data().write(to: manager.directory)
        manager.show(artwork: image(70))
        precondition(!manager.isShowing && manager.artworkChangeCancellable == nil,
                     "Failed initial persistence must not start visible-only subscriptions")
    }
}
