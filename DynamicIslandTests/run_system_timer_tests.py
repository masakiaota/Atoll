#!/usr/bin/env python3
"""Test the production timer monitor with a fake process and isolated preferences."""

import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent


def prepare_test(directory):
    source = (ROOT / "DynamicIsland/managers/SystemTimerBridge.swift").read_text()

    def method(name):
        pattern = r"^    private init\(" if name == "init" else r"^    private func " + name + r"\b"
        match = re.search(pattern, source, re.M)
        if not match:
            raise ValueError(f"Timer bridge method not found: {name}")
        start = source.index("{", match.start())
        depth, end = 1, start + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        return source[match.start():end].replace("private ", "", 1)

    names = ["init", "startIfNeeded", "stopMonitoring", "setupTicker", "startLogStream",
             "stopLogStream", "handleLogStreamTermination", "scheduleLogStreamRestart",
             "consumeLogData", "startFileMonitor"]
    fields = []
    for name in ["queue", "metadata", "initialTotalDuration", "latestRemaining", "latestPaused",
                 "latestUpdateTimestamp", "logProcess", "logReader", "logBuffer", "logRestartWorkItem",
                 "logPreferredName", "logPreferredDuration", "logIdentifier", "logDidCompleteActiveTimer",
                 "nonJSONLogLineCount", "pendingMainUpdate", "menuExtra", "fileMonitor", "ticker",
                 "defaultsCancellable"]:
        match = re.search(r"^    private (?:let|var) " + name + r"\b.*$", source, re.M)
        if not match:
            raise ValueError(f"Timer bridge field not found: {name}")
        fields.append(match[0].replace("private ", "", 1))

    constants = (ROOT / "DynamicIsland/models/Constants.swift").read_text()
    default = re.search(r'Key<Bool>\("mirrorSystemTimer", default: (true|false)\)', constants)
    if not default:
        raise ValueError("mirrorSystemTimer default not found")
    fixture = (ROOT / "DynamicIslandTests/SystemTimerTests.swift").read_text()
    fixture = fixture.replace("DEFAULT_MIRROR_SYSTEM_TIMER", default[1])
    fixture = fixture.replace("// TIMER_BRIDGE_METHODS", "\n".join(fields + [method(n) for n in names]))
    (Path(directory) / "SystemTimerTests.swift").write_text(fixture)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--prepare"]:
        prepare_test(sys.argv[2])
    else:
        os.execv(sys.executable, [sys.executable, str(ROOT / "scripts/test.py"), "system-timer", *sys.argv[1:]])
