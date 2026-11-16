"""PhotoMotion-only image entrypoint; existing AI image entrypoint is unchanged."""
import os
import math
import threading
import time

from http_adapter import Runtime, PrivateHTTPServer, make_handler
from photo_motion_profile import MODE, PROFILE, OPENING_PROFILE


class PhotoMotionRuntime(Runtime):
    def enqueue(self, task):
        actions={PROFILE:{"compose","inspect_audio"}, OPENING_PROFILE:{"compose","inspect_audio"},
                 "aerial-opening-input-v1":{"prepare_image"}, "aerial-opening-qualify-cfr24":{"compose"}}
        if (not isinstance(task, dict) or task.get("source_mode") != MODE
                or task.get("action") not in actions.get(task.get("composition_profile"),set())):
            raise ValueError("photo_motion_only_image")
        return super().enqueue(task)


def deadline_seconds(raw, now_ms):
    if not isinstance(raw, str) or not raw.isdecimal() or len(raw) > 16 or not math.isfinite(now_ms):
        raise ValueError("photo_motion_deadline_required")
    remaining = int(raw) - now_ms
    if not 0 < remaining <= 20*60*1000:
        raise ValueError("photo_motion_deadline_required")
    return remaining/1000


def arm_deadline(raw):
    # This image is a single private PID1/CPU job. Exiting it also stops the
    # container's descendants; no timed-out encoder can keep its CPU alive.
    timer = threading.Timer(deadline_seconds(raw, time.time()*1000), os._exit, args=(124,))
    timer.daemon = True
    timer.start()
    return timer


if __name__ == "__main__":
    token = os.environ.get("CONTAINER_TOKEN", "")
    hosts = set(filter(None, os.environ.get("MEDIA_HOSTS", "").split(",")))
    if len(token) < 32 or not hosts:
        raise SystemExit("private_renderer_configuration_missing")
    arm_deadline(os.environ.get("PHOTO_MOTION_STOP_AT_MS", ""))
    runtime = PhotoMotionRuntime(token, hosts)
    PrivateHTTPServer(("0.0.0.0", 8080), make_handler(runtime)).serve_forever()
