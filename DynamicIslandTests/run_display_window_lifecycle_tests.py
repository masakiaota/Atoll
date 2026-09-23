#!/usr/bin/env python3
"""Compile AppDelegate's actual window methods with isolated service fixtures.

This keeps the regression test independent of app startup and package services,
without adding test-only routing or lifecycle hooks to production code.
"""

from pathlib import Path
import re
import os
import sys


ROOT = Path(__file__).resolve().parent.parent
if __name__ == "__main__" and sys.argv[1:2] != ["--prepare"]:
    os.execv(sys.executable, [sys.executable, str(ROOT / "scripts/test.py"), "display-lifecycle", *sys.argv[1:]])

source = (ROOT / "DynamicIsland/DynamicIslandApp.swift").read_text()


def method(name):
    match = re.search(r"^    (?:private |@objc )?func " + name + r"\b", source, re.M)
    if not match:
        raise ValueError(f"AppDelegate method not found: {name}")
    start = source.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return (source[match.start():end]
            .replace("private func", "func", 1)
            .replace("NSScreen.screens", "ScreenSource.current")
            .replace("NSScreen.main", "ScreenSource.current.first"))


names = [
    "closeSingleDisplayWindow", "closeAllDisplayWindows", "closeDynamicIslandWindow",
    "reconcileWindowsForDisplayMode", "positionWindow", "resizeWindows", "resizeWindow",
    "restoreFocusTaskWindowsAfterTransition", "screenConfigurationDidChange",
    "adjustWindowPosition",
]
fields = []
for name in ["windows", "viewModels"]:
    match = re.search(r"^    var " + name + r":.*$", source, re.M)
    if not match:
        raise ValueError(f"AppDelegate field not found: {name}")
    fields.append(match[0])

fixture = (ROOT / "DynamicIslandTests/DisplayWindowLifecycleTests.swift").read_text()
fixture = fixture.replace("// APP_DELEGATE_METHODS", "\n".join(fields + [method(n) for n in names]))
def prepare_test(directory):
    directory = Path(directory)
    swift = directory / "DisplayWindowLifecycleTests.swift"
    swift.write_text(fixture)


if __name__ == "__main__":
    prepare_test(sys.argv[2])
