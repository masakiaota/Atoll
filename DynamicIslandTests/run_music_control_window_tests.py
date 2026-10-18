#!/usr/bin/env python3
"""Compile the actual music panel manager with isolated app service fixtures."""

import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent


def prepare_test(directory):
    source = (ROOT / "DynamicIsland/managers/MusicControlWindowManager.swift").read_text()
    # Only the external window-space service is replaced by the Swift fixture.
    (Path(directory) / "MusicControlWindowManager.swift").write_text(
        source.replace("import SkyLightWindow\n", "")
    )


if __name__ == "__main__":
    if sys.argv[1:2] == ["--prepare"]:
        prepare_test(sys.argv[2])
    else:
        os.execv(sys.executable, [sys.executable, str(ROOT / "scripts/test.py"), "music-controls", *sys.argv[1:]])
