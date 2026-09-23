#!/usr/bin/env python3
"""Run a command silently on success; retain a full log and bounded diagnostics on failure."""

import argparse
import math
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAX_BYTES = 8192
MAX_LINES = 80


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupt(signum, _frame):
    raise Interrupted(signum)


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("timeout must be a positive finite number")
    return seconds


def stop(process):
    # Kill the process group, including compiler/test children, even if its
    # leader has already exited. A timed-out test must not continue in the background.
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=2)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def report(log, code, label):
    header = f"FAIL: {label[:200]} (exit {code})\nFull log: {log}\n".encode()
    with log.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        stream.seek(max(0, stream.tell() - MAX_BYTES))
        tail = stream.read().decode("utf-8", errors="replace")
    tail = "\n".join(tail.splitlines()[-(MAX_LINES - 2):]) + "\n"
    tail = tail.encode()[-max(0, MAX_BYTES - len(header)):].decode("utf-8", errors="ignore").encode()
    sys.stderr.buffer.write(header + tail)
    sys.stderr.buffer.flush()


def run(command, *, log_dir=ROOT / ".test-results", timeout=None, verbose=False, label=None):
    log_dir = Path(log_dir).resolve()
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix="command-", suffix=".log", dir=log_dir)
    except OSError as error:
        print(f"Cannot create command log: {error}", file=sys.stderr)
        return 126
    log = Path(name)
    process = None
    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(("$ " + shlex.join(command) + "\n").encode())
            output.flush()
            try:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                code = process.wait(timeout=timeout)
                if code < 0:
                    stop(process)
                    code = 128 - code
            except (OSError, subprocess.TimeoutExpired, KeyboardInterrupt, Interrupted) as error:
                if process is not None:
                    stop(process)
                if isinstance(error, subprocess.TimeoutExpired):
                    code, reason = 124, f"Timed out after {timeout} seconds"
                elif isinstance(error, (KeyboardInterrupt, Interrupted)):
                    signum = error.signum if isinstance(error, Interrupted) else signal.SIGINT
                    code, reason = 128 + signum, f"Interrupted by signal {signum}"
                else:
                    code = 127 if isinstance(error, FileNotFoundError) else 126
                    reason = f"Could not start command: {error}"
                output.write(("\n" + reason + "\n").encode())
    finally:
        signal.signal(signal.SIGTERM, previous)

    if verbose:
        with log.open("rb") as output:
            shutil.copyfileobj(output, sys.stdout.buffer)
        sys.stdout.buffer.flush()
    if code:
        report(log, code, label or Path(command[0]).name)
    else:
        log.unlink()
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", type=Path, default=ROOT / ".test-results")
    parser.add_argument("--timeout", type=positive_seconds)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    return run(command, log_dir=args.log_dir, timeout=args.timeout, verbose=args.verbose)


if __name__ == "__main__":
    sys.exit(main())
