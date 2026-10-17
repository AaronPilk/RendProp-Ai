#!/usr/bin/env python3
"""Two synthetic rawvideo stdin commands; never imports product or uses a URL."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import selectors
import shutil
import signal
import subprocess
import sys
import time

BASE = '5b9a6ff8d36f639d6abd23876af0953ff397b901'
SOURCE = 'services/edge/property-video-render/container/smooth_finish.py'
SOURCE_SHA = '815e413abd640e4ca146bdb892e15246e8565a673f76b57fb58c8fd746ab037f'
CAP = 1024 * 1024


def write(path, data):
    if not isinstance(data, bytes):
        data = (json.dumps(data, indent=2, allow_nan=False) + '\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def command(argv, data, deadline, *, stdout_cap=CAP):
    """Drain error and input concurrently, retaining a precise broken-pipe fact."""
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    output, error, offset, broken, refused = bytearray(), bytearray(), 0, False, None
    try:
        for pipe, tag, event in [(process.stdout, 'out', selectors.EVENT_READ),
                                 (process.stderr, 'err', selectors.EVENT_READ),
                                 (process.stdin, 'in', selectors.EVENT_WRITE)]:
            if pipe is not None:
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, event, tag)
        while selector.get_map() or process.poll() is None:
            if time.monotonic() >= deadline:
                raise RuntimeError('command_deadline')
            for key, _ in selector.select(.05):
                if key.data == 'in':
                    try:
                        offset += os.write(key.fd, data[offset:offset + 65536])
                    except BrokenPipeError:
                        broken = True
                    except BlockingIOError:
                        continue
                    if broken or offset == len(data):
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                else:
                    try:
                        part = os.read(key.fd, 65536)
                    except BlockingIOError:
                        continue
                    if not part:
                        selector.unregister(key.fileobj)
                        continue
                    target, limit = (output, stdout_cap) if key.data == 'out' else (error, CAP)
                    if len(target) + len(part) > limit:
                        raise RuntimeError('output_cap')
                    target.extend(part)
        process.wait(timeout=1)
        if time.monotonic() >= deadline:
            raise RuntimeError('command_deadline')
    except Exception as exc:
        refused = type(exc).__name__ + ':' + str(exc)
    finally:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                refused = 'owned_child_cleanup_timeout'
        selector.close()
        for pipe in (process.stdin, process.stdout, process.stderr):
            if pipe is not None and not pipe.closed:
                pipe.close()
    return {'exitCode': process.returncode, 'stdinBytesWritten': offset,
            'brokenPipeObserved': broken, 'refusal': refused}, bytes(output), bytes(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(mode=0o700)
    start = time.monotonic()
    whole = start + 110
    source = Path(SOURCE).read_bytes()
    assert hashlib.sha256(source).hexdigest() == SOURCE_SHA, 'source_binding'
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    assert ffmpeg and ffprobe
    intent = {'purpose': 'SYNTHETIC_RAWVIDEO_STDIN_PROTOCOL_DIAGNOSTIC', 'base': BASE,
              'sourcePath': SOURCE, 'sourceSHA256': SOURCE_SHA,
              'python': sys.version, 'ffmpeg': ffmpeg, 'ffprobe': ffprobe,
              'wholeSeconds': 110, 'eachEncodeSeconds': 20, 'probeSeconds': 10,
              'stderrAndStdoutCapEachBytes': CAP, 'networkOrProviderCalls': 0}
    write(args.output_dir / 'INTENT.json', intent)
    result = {'status': 'DIAGNOSTIC_INCOMPLETE', 'cases': [], 'sourceSHA256': SOURCE_SHA,
              'featureSourceChanged': False, 'provesOtherEncoderPaths': False}
    try:
        for tool in (ffmpeg, ffprobe):
            facts, out, err = command([tool, '-version'], None, min(whole, time.monotonic() + 5))
            write(args.output_dir / (Path(tool).name + '.version.stdout.log'), out)
            write(args.output_dir / (Path(tool).name + '.version.stderr.log'), err)
            assert facts['exitCode'] == 0 and facts['refusal'] is None, 'tool_identity'
            if tool == ffmpeg:
                assert out.startswith(b'ffmpeg version 6.1.1'), 'expected_failed_job_ffmpeg_version'
        width, height, frames, fps = 1920, 1080, 3, 24
        # One deterministic neutral YUV420p frame, repeated exactly three times.
        frame = bytes([80]) * (width * height) + bytes([128]) * (width * height // 2)
        data = frame * frames
        assert len(data) == 9331200
        for label, stdin_url in [('original-dash', '-'), ('explicit-pipe0', 'pipe:0')]:
            output = args.output_dir / (label + '.mp4')
            tail = ['-an', '-frames:v', '3', '-c:v', 'libx264', '-preset', 'ultrafast',
                    '-crf', '18', '-maxrate', '24M', '-bufsize', '48M', '-threads', '2',
                    '-pix_fmt', 'yuv420p', '-color_primaries', 'bt709', '-color_trc', 'bt709',
                    '-colorspace', 'bt709', '-movflags', '+faststart', str(output)]
            argv = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
                    '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-s', '1920x1080', '-r', '24',
                    '-protocol_whitelist', 'file,pipe', '-i', stdin_url, *tail]
            facts, out, err = command(argv, data, min(whole, time.monotonic() + 20))
            write(args.output_dir / (label + '.stdout.log'), out)
            write(args.output_dir / (label + '.stderr.log'), err)
            row = {'name': label, 'argv': argv, **facts, 'stderrSHA256': hashlib.sha256(err).hexdigest(),
                   'outputExists': output.exists(), 'outputBytes': output.stat().st_size if output.exists() else 0}
            result['cases'].append(row)
            assert facts['refusal'] is None, 'diagnostic_process_refusal'
            if label == 'original-dash':
                assert facts['exitCode'] != 0 and b"Protocol 'fd' not on whitelist 'file,pipe'" in err, 'exact_fd_whitelist_witness'
                assert not output.exists() or output.stat().st_size == 0, 'failed_command_output'
            else:
                assert facts['exitCode'] == 0 and row['outputBytes'] > 0, 'explicit_pipe_encoding'
                assert row['outputBytes'] <= 2 * 1024 * 1024, 'media_output_cap'
                probe_argv = [ffprobe, '-v', 'error', '-count_frames', '-show_streams', '-show_format', '-of', 'json', str(output)]
                probe, raw, error = command(probe_argv, None, min(whole, time.monotonic() + 10))
                write(args.output_dir / 'explicit-pipe0.probe.stdout.json', raw)
                write(args.output_dir / 'explicit-pipe0.probe.stderr.log', error)
                assert probe['exitCode'] == 0 and probe['refusal'] is None, 'probe_exit'
                parsed = json.loads(raw)
                streams = parsed['streams']
                assert len(streams) == 1 and streams[0]['codec_type'] == 'video'
                stream = streams[0]
                assert stream['codec_name'] == 'h264' and (stream['width'], stream['height']) == (width, height)
                assert stream['avg_frame_rate'] == '24/1' and int(stream['nb_read_frames']) == frames
                assert abs(float(parsed['format']['duration']) - frames / fps) < .01
                row['probe'] = parsed
                row['outputSHA256'] = hashlib.sha256(output.read_bytes()).hexdigest()
        assert hashlib.sha256(Path(SOURCE).read_bytes()).hexdigest() == SOURCE_SHA, 'source_end_binding'
        assert time.monotonic() < whole, 'whole_deadline'
        result['status'] = 'EXACT_FD_REFUSAL_AND_EXPLICIT_PIPE_THREE_FRAME_POSITIVE'
    except Exception as error:
        result['failure'] = type(error).__name__ + ':' + str(error)
    finally:
        result['seconds'] = time.monotonic() - start
        write(args.output_dir / 'RESULT.json', result)
    print(json.dumps({'status': result['status'], 'cases': len(result['cases']), 'seconds': result['seconds']}))
    return 0 if result['status'] == 'EXACT_FD_REFUSAL_AND_EXPLICIT_PIPE_THREE_FRAME_POSITIVE' else 1


if __name__ == '__main__':
    raise SystemExit(main())
