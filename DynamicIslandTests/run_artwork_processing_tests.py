#!/usr/bin/env python3
"""Exercise production artwork processing without changing the user's wallpaper."""

import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent


def prepare_test(directory):
    source = (ROOT / "DynamicIsland/managers/FullScreenArtworkWindowManager.swift").read_text()

    def method(name):
        pattern = (r"^    private init\(" if name == "init" else
                   r"^    (?:private )?(?:nonisolated )?func " + name + r"\b")
        match = re.search(pattern, source, re.M)
        if not match:
            raise ValueError(f"Artwork manager method not found: {name}")
        start = source.index("{", match.start())
        depth, end = 1, start + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        return source[match.start():end].replace("private ", "", 1)

    names = [
        "init", "show", "hide", "observeArtworkChanges", "observeTrackChanges",
        "scheduleDeferredTrackRefresh", "applyPresentation", "refreshPresentationForCurrentTrack",
        "persistedArtworkFile", "encodeToPNG", "imageFingerprint",
        "shouldUseSpotifyStaticFallbackWallpaper", "resolvedVideoURL", "artworkOverlayMode",
        "wallpaperIdentityKey", "wallpaperPixelSize",
    ]
    fields = []
    for name in [
        "isShowing", "isShowingSpotifyCanvasFallback", "onDismiss", "artworkFileURL",
        "cachedArtworkPNG", "cachedArtworkFingerprint", "activeSongTitle", "activeArtist",
        "trackChangeCancellable", "artworkChangeCancellable", "liveWallpaperTask",
        "deferredTrackRefreshTask", "isLiveWallpaperAllowed", "activeLiveWallpaperFingerprint",
        "activeWallpaperKey", "pendingFallbackStaticURL", "pendingFallbackWallpaperKey",
    ]:
        match = re.search(r"^    (?:@Published )?(?:private(?:\(set\))? )?var " + name + r"\b.*$", source, re.M)
        if not match:
            raise ValueError(f"Artwork manager field not found: {name}")
        fields.append(match[0].replace("private(set) ", "").replace("private ", ""))

    fixture = (ROOT / "DynamicIslandTests/ArtworkProcessingTests.swift").read_text()
    fixture = fixture.replace("// ARTWORK_MANAGER_METHODS", "\n".join(fields + [method(n) for n in names]))
    (Path(directory) / "ArtworkProcessingTests.swift").write_text(fixture)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--prepare"]:
        prepare_test(sys.argv[2])
    else:
        os.execv(sys.executable, [sys.executable, str(ROOT / "scripts/test.py"), "artwork-processing", *sys.argv[1:]])
