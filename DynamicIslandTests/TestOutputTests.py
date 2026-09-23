import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
QUIET = ROOT / "scripts/quiet.py"


class TestOutputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="atoll-output-tests-")
        self.addCleanup(self.directory.cleanup)
        self.logs = Path(self.directory.name) / "logs"

    def command(self, script, *options):
        return [sys.executable, str(QUIET), "--log-dir", str(self.logs), *options,
                "--", sys.executable, "-c", script]

    def invoke(self, script, *options):
        return subprocess.run(self.command(script, *options), capture_output=True, timeout=10)

    def test_success_is_silent_and_removes_log(self):
        result = self.invoke("import sys; print('passed' * 10000); print('warning' * 10000, file=sys.stderr)")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        self.assertEqual(list(self.logs.iterdir()), [])

    def test_failure_is_bounded_and_preserves_full_log_and_exit_code(self):
        result = self.invoke("import sys; print('context\\n' * 10000); print('x' * 20000); print('actual failure', file=sys.stderr); sys.exit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, b"")
        self.assertLessEqual(len(result.stderr), 8192)
        self.assertLessEqual(len(result.stderr.splitlines()), 80)
        log, = self.logs.glob("*.log")
        self.assertIn(str(log).encode(), result.stderr)
        self.assertIn(b"actual failure", log.read_bytes())
        self.assertGreater(log.stat().st_size, 80000)

    def test_multibyte_diagnostics_obey_byte_limit(self):
        result = self.invoke("import sys; print('失敗' * 10000); sys.exit(1)")
        self.assertLessEqual(len(result.stderr), 8192)
        result.stderr.decode("utf-8")

    def test_missing_command_is_not_success(self):
        result = subprocess.run([sys.executable, str(QUIET), "--log-dir", str(self.logs), "--", "/missing-atoll-test-command"], capture_output=True)
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"Could not start command", result.stderr)

    def test_log_creation_failure_does_not_execute_command(self):
        self.logs.write_text("not a directory")
        marker = Path(self.directory.name) / "executed"
        result = self.invoke(f"import pathlib; pathlib.Path({str(marker)!r}).touch()")
        self.assertEqual(result.returncode, 126)
        self.assertIn(b"Cannot create command log", result.stderr)
        self.assertFalse(marker.exists())

    def test_invalid_timeout_is_rejected(self):
        for timeout in ("0", "-1", "nan", "inf"):
            result = self.invoke("raise SystemExit(0)", "--timeout", timeout)
            self.assertNotEqual(result.returncode, 0)

    def test_timeout_stops_children_and_keeps_diagnostics(self):
        pid_file = Path(self.directory.name) / "child-pid"
        child = f"import os,time,pathlib; pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(20)"
        result = self.invoke(f"import subprocess,sys,time; subprocess.Popen([sys.executable, '-c', {child!r}]); time.sleep(20)", "--timeout", "1")
        self.assertEqual(result.returncode, 124)
        self.assertIn(b"Timed out", result.stderr)
        self.assertTrue(pid_file.exists(), "The descendant must have started before the timeout")
        status = subprocess.run(["ps", "-p", pid_file.read_text(), "-o", "stat="], capture_output=True, text=True)
        self.assertTrue(not status.stdout.strip() or status.stdout.lstrip().startswith("Z"),
                        "Timeout must terminate descendants, not just their parent")

    def test_interrupt_is_not_success(self):
        ready = Path(self.directory.name) / "ready"
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                ready.unlink(missing_ok=True)
                command = self.command(f"import pathlib,time; pathlib.Path({str(ready)!r}).touch(); time.sleep(20)")
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 5
                    while not ready.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.exists())
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 128 + signum)
                    self.assertEqual(stdout, b"")
                    self.assertIn(b"Interrupted", stderr)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()

    def test_child_signal_exit_is_preserved(self):
        result = self.invoke("import os,signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(result.returncode, 128 + signal.SIGTERM)

    def test_explicit_verbose_mode_shows_success_log(self):
        result = self.invoke("print('detail requested')", "--verbose")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"detail requested", result.stdout)
        self.assertEqual(result.stderr, b"")

    def test_empty_command_and_unknown_suite_are_errors(self):
        for command in ([str(QUIET)], [str(ROOT / "scripts/test.py"), "not-a-suite"]):
            result = subprocess.run([sys.executable, *command], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_runs_do_not_overwrite_each_others_logs(self):
        self.invoke("raise SystemExit(3)")
        self.invoke("raise SystemExit(4)")
        self.assertEqual(len(list(self.logs.glob("*.log"))), 2)

    def test_default_selection_includes_every_suite(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        import test as runner
        previous_directory = Path.cwd()
        try:
            with mock.patch.object(sys, "argv", ["test.py"]), \
                 mock.patch.object(runner, "ROOT", Path(self.directory.name)), \
                 mock.patch.object(runner, "run", return_value=0) as run:
                self.assertEqual(runner.main(), 0)
                labels = {call.kwargs["label"].split(":")[0] for call in run.call_args_list}
                self.assertEqual(labels, set(runner.STANDALONE + ["ui"]))
        finally:
            os.chdir(previous_directory)
            sys.path.pop(0)


if __name__ == "__main__":
    unittest.main()
