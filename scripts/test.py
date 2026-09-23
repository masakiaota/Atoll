#!/usr/bin/env python3
"""Standard test entry point. Successful runs produce no stdout or stderr."""

import argparse
import os
from pathlib import Path
import sys
import tempfile

from quiet import ROOT, positive_seconds, run

SWIFT_TESTS = {
    "hidden-edge": ["DynamicIsland/helpers/HiddenEdgeHoverPollingState.swift", "DynamicIslandTests/HiddenEdgeHoverPollingStateTests.swift"],
    "localsend": ["DynamicIsland/components/Shelf/Services/LocalSendDiscoveryUsage.swift", "Tests/LocalSendDiscoveryUsage/main.swift"],
    "layout": ["DynamicIsland/helpers/NotchMenuBarLayout.swift", "DynamicIslandTests/NotchMenuBarLayoutTests.swift"],
    "input": ["DynamicIsland/components/Notch/DynamicIslandWindow.swift", "DynamicIslandTests/NotchMouseRegionTests.swift"],
    "surface": ["DynamicIsland/components/Notch/NotchSurface.swift", "DynamicIsland/components/Notch/NotchShape.swift", "DynamicIslandTests/NotchSurfaceTests.swift"],
    "display-lifecycle": ["DynamicIsland/extensions/NSScreen+DisplayID.swift", "DynamicIsland/helpers/NotchMenuBarLayout.swift", "DynamicIsland/components/Notch/DynamicIslandWindow.swift"],
}
UNIT = ["output", "hidden-edge", "localsend"]
STANDALONE = UNIT + ["layout", "input", "surface", "display-lifecycle"]
GROUPS = {"unit": UNIT, "standalone": STANDALONE, "all": STANDALONE + ["ui"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    available = list(GROUPS) + STANDALONE + ["ui"]
    parser.add_argument("suites", nargs="*", metavar="SUITE", help=", ".join(available))
    parser.add_argument("--verbose", action="store_true", help="show complete command logs after execution")
    parser.add_argument("--timeout", type=positive_seconds, default=900, help="timeout in seconds per command (default: 900)")
    args = parser.parse_args()
    unknown = set(args.suites) - set(available)
    if unknown:
        parser.error("unknown suite: " + ", ".join(sorted(unknown)))
    suites = list(dict.fromkeys(name for selected in (args.suites or ["all"])
                               for name in GROUPS.get(selected, [selected])))
    os.chdir(ROOT)
    options = {"timeout": args.timeout, "verbose": args.verbose}
    with tempfile.TemporaryDirectory(prefix="atoll-tests-") as directory:
        directory = Path(directory)
        for suite in suites:
            if suite == "output":
                commands = [[sys.executable, "DynamicIslandTests/TestOutputTests.py"]]
            elif suite == "ui":
                results = ROOT / ".test-results"
                results.mkdir(exist_ok=True)
                result = Path(tempfile.mkdtemp(prefix="ui-", dir=results)) / "Tests.xcresult"
                commands = [["xcodebuild", "test", "-project", "DynamicIsland.xcodeproj", "-scheme", "DynamicIsland",
                             "-destination", "platform=macOS", "-derivedDataPath", "DerivedData", "-resultBundlePath", str(result)]]
            else:
                sources = list(SWIFT_TESTS[suite])
                commands = []
                if suite == "display-lifecycle":
                    commands.append([sys.executable, "DynamicIslandTests/run_display_window_lifecycle_tests.py", "--prepare", str(directory)])
                    sources.append(directory / "DisplayWindowLifecycleTests.swift")
                executable = directory / suite
                commands += [["xcrun", "swiftc", *map(str, sources), "-o", str(executable)], [str(executable)]]
            for command in commands:
                code = run(command, label=f"{suite}: {Path(command[0]).name}", **options)
                if code:
                    return code
    return 0


if __name__ == "__main__":
    sys.exit(main())
