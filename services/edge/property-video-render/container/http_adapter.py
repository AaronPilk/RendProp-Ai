"""Private asynchronous CPU HTTP adapter. No public routes or billable calls."""
import concurrent.futures
import hashlib
import hmac
import json
import os
import shutil
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

from renderer import render, upload_prepared, validate_task


class Runtime:
    def __init__(self, token, hosts, work_root="/work", runner=render, uploader=upload_prepared):
        self.token, self.hosts, self.work_root = token, hosts, work_root
        self.runner, self.uploader = runner, uploader
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.lock = threading.Lock()
        self.task_id, self.task, self.future, self.prepared = None, None, None, None
        self.uploading = False

    def enqueue(self, task):
        validate_task(task)
        task_id = hashlib.sha256(json.dumps(task, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with self.lock:
            if task_id == self.task_id:
                return task_id
            if self.task_id:
                raise PermissionError("busy")
            self.task_id, self.task = task_id, task
            self.future = self.pool.submit(self.runner, task, self.hosts, self.work_root)
        return task_id

    def status(self, task_id):
        with self.lock:
            if task_id != self.task_id:
                return {"state": "missing"}
            if not self.future.done():
                return {"state": "working"}
            if self.future.exception():
                return {"state": "failed", "code": "cpu_media_refused"}
            value = self.future.result()
            if self.uploading:
                return {"state": "uploaded", "result": value}
            self.prepared = value
            result = value["result"]
            return {"state": "prepared" if self.task["action"] in {"compose", "prepare_image"} else "inspected" if self.task["action"] == "inspect_audio" else "extracted",
                    "result": result["receipt"] if self.task["action"] in {"compose", "prepare_image"} else result}

    def start_upload(self, task_id, output):
        with self.lock:
            if task_id != self.task_id or self.task["action"] not in {"compose", "prepare_image"} or not self.prepared:
                raise ValueError("prepared_task_required")
            if self.uploading:
                return
            self.uploading = True
            self.future = self.pool.submit(self.uploader, self.prepared, output, self.hosts)

    def discard(self, task_id):
        with self.lock:
            if task_id != self.task_id or not self.future.done():
                raise ValueError("terminal_task_required")
            if self.prepared:
                shutil.rmtree(self.prepared["directory"], ignore_errors=True)
            elif not self.future.exception():
                shutil.rmtree(self.future.result()["directory"], ignore_errors=True)
            self.task_id = self.task = self.future = self.prepared = None
            self.uploading = False

    def close(self):
        self.pool.shutdown(wait=True)
        if self.task_id:
            self.discard(self.task_id)



class PrivateHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer's reverse-DNS display name is unused by our handler. A
        # 64-character container hostname is not a valid single IDNA label and
        # makes socket.getfqdn() raise before the private port can be served.
        TCPServer.server_bind(self)
        self.server_name = "private-renderer"
        self.server_port = self.server_address[1]


def make_handler(runtime):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args):
            pass  # Never log signed media URLs, identity claims or tokens.

        def reply(self, status, value):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/ready":
                self.reply(200, {"ready": True, "provider_dispatch": False})
            else:
                self.reply(404, {"error": "not_found"})

        def do_POST(self):
            if not runtime.token or not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + runtime.token):
                self.close_connection = True
                self.reply(403, {"error": "private_container_only"})
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 1 <= size <= 1024 * 1024 or self.headers.get("Transfer-Encoding"):
                    raise ValueError("bounded_body_required")
                body = json.loads(self.rfile.read(size))
                if self.path == "/execute":
                    self.reply(202, {"task_id": runtime.enqueue(body)})
                elif self.path == "/status" and set(body) == {"task_id"}:
                    self.reply(200, runtime.status(body["task_id"]))
                elif self.path == "/upload" and set(body) == {"task_id", "output"}:
                    runtime.start_upload(body["task_id"], body["output"])
                    self.reply(202, {"accepted": True})
                elif self.path == "/discard" and set(body) == {"task_id"}:
                    runtime.discard(body["task_id"])
                    self.reply(200, {"discarded": True})
                else:
                    self.reply(404, {"error": "not_found"})
            except PermissionError:
                self.reply(409, {"error": "cpu_busy"})
            except (ValueError, TypeError, KeyError):
                self.reply(400, {"error": "invalid_or_stale_task"})
    return Handler


if __name__ == "__main__":
    token = os.environ.get("CONTAINER_TOKEN", "")
    hosts = set(filter(None, os.environ.get("MEDIA_HOSTS", "").split(",")))
    if len(token) < 32 or not hosts:
        raise SystemExit("private_renderer_configuration_missing")
    runtime = Runtime(token, hosts)
    PrivateHTTPServer(("0.0.0.0", 8080), make_handler(runtime)).serve_forever()
