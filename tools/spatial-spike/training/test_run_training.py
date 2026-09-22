import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import unittest

from prepare_capture import CaptureError, load_capture, write_dataset
from test_prepare_capture import fixture
from run_training import bounded_process, training_command, validate_dataset


class TrainingGuardTests(unittest.TestCase):
    def test_caps_reject_out_of_bounds(self):
        for steps, points in ((0,100), (7001,100), (100,99), (100,500001)):
            with self.subTest(steps=steps, points=points), self.assertRaises(CaptureError):
                training_command("python", "/trainer", "/dataset", "/output", steps, points)

    def test_command_disables_pose_and_world_changes_and_caps_mcmc(self):
        command = training_command("python", "/trainer", "/dataset", "/output", 3000, 500000)
        self.assertEqual(command[2], "mcmc")
        for flag in ("--no-pose-opt", "--no-normalize-world-space", "--disable-viewer", "--disable-video"):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index("--strategy.cap-max")+1], "500000")

    def test_process_failure_and_timeout_are_real_failures(self):
        result, _ = bounded_process([sys.executable, "-c", "raise SystemExit(7)"], 5)
        self.assertEqual(result, 7)
        with self.assertRaisesRegex(CaptureError, "wall-clock"):
            bounded_process([sys.executable, "-c", "import time; time.sleep(30)"], 0.05)
        for timeout in (0,1801):
            with self.assertRaises(CaptureError):
                bounded_process([sys.executable, "-c", "pass"], timeout)

    def test_interrupts_stop_detached_training_child_and_restore_handlers(self):
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signum):
                helper = (
                    "import signal,sys; from run_training import bounded_process; "
                    "from prepare_capture import CaptureError; "
                    "old={s:signal.getsignal(s) for s in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP)}\n"
                    "try:\n"
                    " bounded_process([sys.executable,'-c','import os,time; print(os.getpid(),flush=True); time.sleep(30)'],20)\n"
                    "except CaptureError:\n"
                    " assert all(signal.getsignal(s)==h for s,h in old.items()); sys.exit(23)\n"
                )
                parent = subprocess.Popen([sys.executable,"-c",helper], cwd=Path(__file__).parent,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    child_pid = int(parent.stdout.readline())
                    parent.send_signal(signum)
                    _, stderr = parent.communicate(timeout=10)
                    self.assertEqual(parent.returncode, 23, stderr)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child_pid, 0)
                finally:
                    if parent.poll() is None:
                        parent.kill()
                        parent.wait()

    def test_timeout_kills_stubborn_grandchild_after_leader_exits(self):
        grandchild = ("import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                      "print(str(os.getpid())+','+str(os.getpgrp()),flush=True); time.sleep(30)")
        trainer = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{grandchild!r}]); time.sleep(30)"
        supervisor = (
            "import sys; from run_training import bounded_process; from prepare_capture import CaptureError\n"
            f"try:\n bounded_process([sys.executable,'-c',{trainer!r}],1.5)\n"
            "except CaptureError:\n sys.exit(23)\n"
        )
        parent = subprocess.Popen([sys.executable,"-c",supervisor], cwd=Path(__file__).parent,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        group = None
        try:
            child_pid, group = map(int, parent.stdout.readline().strip().split(","))
            _, stderr = parent.communicate(timeout=10)
            self.assertEqual(parent.returncode, 23, stderr)
            # An orphan killed under Linux may briefly remain a zombie until
            # PID 1 reaps it. Either absence or Z proves it cannot keep training.
            status = subprocess.run(["ps","-p",str(child_pid),"-o","stat="], capture_output=True, text=True)
            self.assertTrue(status.returncode == 1 or status.stdout.strip().startswith("Z"), status.stdout)
        finally:
            if group is not None:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if parent.poll() is None:
                parent.kill()
                parent.wait()

    def test_modified_model_or_images_block_training(self):
        with tempfile.TemporaryDirectory(prefix="spatial-guard-test-") as directory:
            root = Path(directory) / "capture"
            root.mkdir()
            fixture(root)
            dataset = Path(directory) / "dataset"
            write_dataset(load_capture(root), dataset)
            self.assertEqual(validate_dataset(dataset, 500000)["frames"], 20)
            model = dataset / "sparse/0/images.bin"
            content = model.read_bytes()
            model.write_bytes(content + b"changed")
            with self.assertRaisesRegex(CaptureError, "changed"):
                validate_dataset(dataset, 500000)
            model.write_bytes(content)
            (dataset / "images/extra.jpg").write_bytes(b"extra")
            with self.assertRaisesRegex(CaptureError, "extra"):
                validate_dataset(dataset, 500000)


if __name__ == "__main__":
    unittest.main()
