"""Bounded local media subprocess I/O, including blocked pipes and descendants.

The deadline applies while reading or writing pipes, not just after they close.
Stderr is drained concurrently and retained only as a bounded tail. Every exit
path reaps the child; failures kill its private process group before cleanup.
"""
from __future__ import annotations

import math
import os
import selectors
import signal
import subprocess
import time


class ProcessDeadlineError(RuntimeError):
    pass


class BoundedProcess:
    STDERR_LIMIT = 16 * 1024
    MAX_READ = 128 * 1024 * 1024

    def __init__(self, args, *, timeout, read_stdout=False, write_stdin=False, deadline=None):
        if (isinstance(timeout, bool) or not isinstance(timeout, (int, float))
                or not math.isfinite(timeout) or timeout <= 0):
            raise ValueError("positive_process_timeout_required")
        now = time.monotonic()
        if deadline is not None and (isinstance(deadline, bool) or not isinstance(deadline, (int, float))
                                     or not math.isfinite(deadline)):
            raise ValueError("finite_process_deadline_required")
        self.deadline = min(now + timeout, deadline) if deadline is not None else now + timeout
        self.selector = selectors.DefaultSelector()
        self.buffer = bytearray()
        self.stderr = bytearray()
        self.closed = False
        self.discard_stdout = False
        try:
            self.process = subprocess.Popen(args, stdin=subprocess.PIPE if write_stdin else subprocess.DEVNULL,
                                            stdout=subprocess.PIPE if read_stdout else subprocess.DEVNULL,
                                            stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
        except BaseException:
            self.selector.close()
            raise
        try:
            for name in ("stdout", "stderr", "stdin"):
                pipe = getattr(self.process, name)
                if pipe is not None:
                    os.set_blocking(pipe.fileno(), False)
                    if name != "stdin":
                        self.selector.register(pipe, selectors.EVENT_READ, name)
            self._remaining()
        except BaseException:
            self.abort()
            raise

    def _remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ProcessDeadlineError("media_process_deadline_exceeded")
        return remaining

    def _close_pipe(self, pipe):
        if pipe is None or pipe.closed:
            return
        try:
            self.selector.unregister(pipe)
        except KeyError:
            pass
        pipe.close()  # unbuffered: no blocking flush

    def _pump(self, pending=None):
        events = self.selector.select(self._remaining())
        self._remaining()
        written = 0
        for key, _ in events:
            if key.data == "stdin":
                if pending:
                    try:
                        written = os.write(key.fd, pending[:65536])
                    except BlockingIOError:
                        pass
                continue
            try:
                chunk = os.read(key.fd, 65536)
            except BlockingIOError:
                continue
            if not chunk:
                self._close_pipe(key.fileobj)
            elif key.data == "stderr":
                self.stderr.extend(chunk)
                del self.stderr[:-self.STDERR_LIMIT]
            elif not self.discard_stdout:
                self.buffer.extend(chunk)
        return written

    def read_exact(self, count):
        if isinstance(count, bool) or not isinstance(count, int) or not 0 < count <= self.MAX_READ:
            raise ValueError("bounded_read_size_required")
        if self.process.stdout is None:
            raise ValueError("stdout_pipe_required")
        while len(self.buffer) < count and not self.process.stdout.closed:
            self._pump()
        self._remaining()
        take = min(count, len(self.buffer))
        value = bytes(self.buffer[:take])
        del self.buffer[:take]
        return value

    def write(self, data):
        pipe = self.process.stdin
        if pipe is None or pipe.closed:
            raise ValueError("stdin_pipe_required")
        view = memoryview(data)
        self.selector.register(pipe, selectors.EVENT_WRITE, "stdin")
        try:
            while view:
                self._remaining()
                written = self._pump(view)
                view = view[written:]
        finally:
            try:
                self.selector.unregister(pipe)
            except KeyError:
                pass

    def finish(self):
        """Close input, drain pipes, and wait within the SAME absolute deadline."""
        self._close_pipe(self.process.stdin)
        self.discard_stdout = True
        self.buffer.clear()
        while self.selector.get_map():
            self._pump()
        try:
            code = self.process.wait(timeout=self._remaining())
        except subprocess.TimeoutExpired as error:
            raise ProcessDeadlineError("media_process_deadline_exceeded") from error
        self._kill_group()
        self.closed = True
        self.selector.close()
        return code

    def _kill_group(self):
        # Kill the private group even if the direct child exited: a descendant
        # may still hold a pipe open. No other application joins this group.
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def abort(self):
        if self.closed:
            return
        try:
            self._kill_group()
        finally:
            for name in ("stdin", "stdout", "stderr"):
                self._close_pipe(getattr(self.process, name))
            self.selector.close()
            self.process.wait(timeout=2)
            self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.abort()
