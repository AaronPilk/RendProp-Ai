#!/usr/bin/env python3
"""Bounded owner-authorized upload proof. No customer IDs, admin key or DELETE.

Private resumable credentials/capabilities never enter the public receipt. A lost
signup response stops instead of manufacturing another identity. Successful PUTs
are reconciled by complete, not resent. Public fixture media is generated here,
never read from the owner's camera roll. This proves transport, not room quality.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

ORIGIN = 'https://ymgqpbnjpztwjsyvceld.supabase.co'
GATEWAY = 'https://uploads.rendprop.com'
RENDERS = 'https://pub-70303ef2ff484a179c03ff19b26aa63d.r2.dev'
ROOT = Path(__file__).resolve().parents[2]


def check(value, label):
    if not value:
        raise AssertionError(label)


def claims(token):
    return json.loads(base64.urlsafe_b64decode(token.split('.')[1] + '==='))


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\x7c\x3a\xed' * 2) * 2)) + chunk(b'IEND', b'')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Proof:
    def __init__(self, directory):
        self.dir = directory.resolve()
        self.dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        check(self.dir.stat().st_mode & 0o077 == 0, 'private directory permissions')
        check(not self.dir.is_relative_to(ROOT), 'credentials must stay outside repository')
        self.path = self.dir / 'private-state.json'
        self.s = json.loads(self.path.read_text()) if self.path.exists() else {'run_id': str(uuid.uuid4()), 'events': [], 'assets': {}}
        config = (ROOT / 'apps/ios/Rendprop/Config.swift').read_text()
        candidates = re.findall(r'"(eyJ[A-Za-z0-9_.-]+)"', config)
        keys = [k for k in candidates if claims(k).get('role') == 'anon' and claims(k).get('ref') == 'ymgqpbnjpztwjsyvceld']
        check(len(keys) == 1, 'one project public anon key')
        self.anon = keys[0]
        self.requests = 0
        self.stage = 'start'
        self.opener = urllib.request.build_opener(NoRedirect())
        self.save()

    def save(self):
        with open(self.path, 'w', opener=lambda p, f: os.open(p, f, 0o600)) as f:
            json.dump(self.s, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(self.path, 0o600)

    def call(self, label, method, url, body=None, kind='json', idem=None, auth=True):
        self.stage = label
        check(method in ('GET', 'POST', 'PUT'), 'no destructive methods')
        u = urllib.parse.urlsplit(url)
        origin = f'{u.scheme}://{u.netloc}'
        check(origin in (ORIGIN, GATEWAY, RENDERS, 'https://tours.rendprop.com', 'https://tour.rendprop.com'), 'exact destination allowlist')
        check(not u.username and not u.password and u.scheme == 'https', 'TLS destination')
        self.requests += 1
        check(self.requests <= 55, 'bounded request count')
        # Python's default urllib signature receives Cloudflare1010 before the
        # Worker runs. Identify this authorized synthetic harness honestly; do
        # not weaken the site's firewall or impersonate an end user's browser.
        headers = {'User-Agent': 'Rendprop-Upload-Proof/1.0'}
        if origin == ORIGIN:
            headers['apikey'] = self.anon
            if auth:
                headers['Authorization'] = 'Bearer ' + self.s['session']['access_token']
        if idem:
            headers['Idempotency-Key'] = idem
        data = None
        if body is not None:
            data = json.dumps(body).encode() if kind == 'json' else body
            check(len(data) <= 2 * 1024 * 1024, 'bounded fixture payload')
            headers['Content-Type'] = 'application/json' if kind == 'json' else kind
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            response = self.opener.open(req, timeout=35)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            raw = response.read(3 * 1024 * 1024 + 1)
            check(len(raw) <= 3 * 1024 * 1024, 'bounded response')
            status = response.code
            h = dict(response.headers.items())
        self.s['events'].append({'step': label, 'method': method, 'origin': origin, 'status': status, 'request_bytes': len(data or b''), 'response_bytes': len(raw), 'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})
        self.save()
        # Neither response bodies nor URL query strings reach stdout.
        print(f'{label}: HTTP {status}', flush=True)
        try:
            result = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            result = raw
        if status >= 400:
            # Protected diagnostic only; a proxy can echo signed request URLs.
            self.s.setdefault('private_errors', []).append({'step': label, 'status': status, 'body': raw.decode('utf-8', errors='replace'), 'headers': h})
            self.save()
        return status, result, h

    def post(self, label, path, body, idem=None):
        return self.call(label, 'POST', ORIGIN + '/functions/v1/' + path, body, idem=idem)

    def setup(self):
        if 'session' not in self.s:
            check(not self.s.get('signup_pending'), 'ambiguous signup must be investigated; do not repeat')
            self.s['signup_pending'] = True
            self.save()
            status, session, _ = self.call('anonymous_signup', 'POST', ORIGIN + '/auth/v1/signup', {}, auth=False)
            check(status == 200 and isinstance(session, dict) and 'access_token' in session, 'anonymous signup receipt')
            check(claims(session['access_token']).get('is_anonymous') is True, 'dedicated anonymous identity')
            self.s['session'] = session
            self.save()
        check(claims(self.s['session']['access_token'])['exp'] > time.time() + 120, 'fixture session still valid; no unplanned refresh')
        if 'listing' not in self.s:
            marker = 'SYNTHETIC UPLOAD PROOF ' + self.s['run_id']
            status, rows, _ = self.call('own_listing_reconciliation', 'GET', ORIGIN + '/functions/v1/listings')
            check(status == 200 and isinstance(rows, list), 'own listing query')
            matches = [r for r in rows if r.get('address') == marker]
            check(len(matches) <= 1, 'no duplicate fixture listings')
            if matches:
                self.s['listing'] = matches[0]
            else:
                check(not self.s.get('listing_pending'), 'ambiguous listing write; reconcile rather than duplicate')
                self.s['listing_pending'] = True
                self.save()
                status, listing, _ = self.post('create_fixture_listing', 'listings', {'address': marker, 'tagline': 'Synthetic engineering fixture, not a property for sale', 'space_type': 'real_estate', 'status': 'draft', 'source': 'manual'})
                check(status == 201 and isinstance(listing, dict) and 'id' in listing, 'listing create receipt')
                self.s['listing'] = listing
            check(self.s['listing']['agent_id'] == self.s['session']['user']['id'], 'fixture listing belongs to isolated identity')
            self.save()

    def asset(self, name, data, content_type, role='capture', multipart=False):
        a = self.s['assets'].setdefault(name, {})
        sha = hashlib.sha256(data).hexdigest()
        spec = {'listing_id': self.s['listing']['id'], 'filename': name, 'bytes': len(data), 'sha256': sha, 'content_type': content_type, 'kind': 'photo' if content_type.startswith('image/') else 'video', 'role': role, 'multipart': multipart}
        if 'ticket' not in a:
            status, ticket, _ = self.post(name + ':ticket', 'uploads', spec, self.s['run_id'] + ':' + name)
            check(status in (200, 201) and isinstance(ticket, dict) and 'asset_id' in ticket, 'ticket receipt')
            a.update(ticket=ticket, sha256=sha, bytes=len(data), role=role)
            self.save()
            # Only replay before any transfer: completed-ticket semantics are a
            # separately tracked client bug, not permission to create new data.
            status, replay, _ = self.post(name + ':ticket_replay', 'uploads', spec, self.s['run_id'] + ':' + name)
            check(status == 200 and replay['asset_id'] == ticket['asset_id'], 'ticket replay same identity')
        check(a['sha256'] == sha, 'resume uses exact original fixture')
        t = a['ticket']
        complete = 'uploads/' + t['asset_id'] + '/complete'
        payload = {'sha256': sha}
        if multipart:
            payload['parts'] = a.get('parts', [])
        status, completed, _ = self.post(name + ':complete_probe', complete, payload)
        if status != 200:
            check(status in (409, 503), 'incomplete upload fails closed')
            if multipart:
                check(t['mode'] == 'multipart' and t['part_count'] == 1 and len(data) <= t['part_size'], 'one small multipart fixture')
                status, urls, _ = self.post(name + ':part_url', 'uploads/' + t['asset_id'] + '/part-urls', {'numbers': [1]})
                check(status == 200 and len(urls['urls']) == 1, 'part URL receipt')
                url = urls['urls'][0]['url']
            else:
                check(t['mode'] == 'single', 'single fixture mode')
                url = t['put_url']
            check(urllib.parse.urlsplit(url).netloc == 'uploads.rendprop.com', 'ticket uses gateway, not reusable R2 PUT')
            check(not a.get('put_pending'), 'ambiguous PUT: complete must reconcile before any retransmission')
            a['put_pending'] = True
            self.save()
            status, _, headers = self.call(name + ':transfer', 'PUT', url, data, content_type, auth=False)
            check(status == 200, 'gateway transfer receipt')
            etag = next((v for k, v in headers.items() if k.lower() == 'etag'), None)
            check(bool(etag), 'server ETag present')
            if multipart:
                a['parts'] = [{'number': 1, 'etag': etag}]
                payload['parts'] = a['parts']
            a['transfer_acknowledged'] = True
            self.save()
            status, completed, _ = self.post(name + ':complete', complete, payload)
        check(status == 200 and completed.get('uploaded') is True and completed.get('bytes') == len(data), 'completed asset has exact observed bytes')
        check(completed.get('transport_version') == 2 and completed.get('id') == t['asset_id'], 'v2 asset identity')
        a['completed'] = completed
        self.save()
        status, replay, _ = self.post(name + ':complete_replay', complete, payload)
        check(status == 200 and replay['id'] == completed['id'] and replay['storage_key'] == completed['storage_key'], 'completion replay immutable key')
        if role == 'render':
            status, fetched, _ = self.call(name + ':final_object_digest', 'GET', RENDERS + '/' + completed['storage_key'], auth=False)
            check(status == 200 and isinstance(fetched, bytes) and hashlib.sha256(fetched).hexdigest() == sha, 'public synthetic object exact SHA-256')
        return a

    def run(self):
        self.setup()
        self.asset('fixture.png', png(), 'image/png')
        video = self.dir / 'synthetic.mp4'
        if not video.exists():
            subprocess.run(['/opt/homebrew/bin/ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x7c3aed:s=64x64:r=10:d=1', '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-n', str(video)], check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        data = video.read_bytes()
        check(0 < len(data) < 100_000, 'tiny synthetic video')
        single = self.asset('single.mp4', data, 'video/mp4', 'render')
        self.asset('multipart.mp4', data, 'video/mp4', 'capture', True)
        publish = {'listing_id': self.s['listing']['id'], 'asset_id': single['completed']['id'], 'duration_s': 1, 'speed_factor': 1, 'tier': 'smooth', 'enhancements': {}, 'chapters': []}
        status, render, _ = self.post('publish_synthetic_app_render', 'renders/publish-app', publish, self.s['run_id'] + ':publish')
        check(status == 201 and isinstance(render, dict) and render.get('video_key') == single['completed']['storage_key'], 'published server-observed final key')
        self.s['render'] = render
        self.save()
        status, replay, _ = self.post('publish_replay', 'renders/publish-app', publish, self.s['run_id'] + ':publish')
        check(status == 201 and replay['id'] == render['id'] and replay['job_id'] == render['job_id'], 'publish replay same render and job')
        receipt = {'result': 'PASS', 'run_id': self.s['run_id'], 'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'fixture_user_id': self.s['session']['user']['id'], 'fixture_org_id': self.s['listing']['org_id'], 'fixture_listing_id': self.s['listing']['id'], 'render_id': render['id'], 'assets': [{'fixture': k, 'asset_id': a['completed']['id'], 'storage_key': a['completed']['storage_key'], 'bytes': a['bytes'], 'sha256': a['sha256'], 'transport_version': 2} for k, a in self.s['assets'].items()], 'events': self.s['events'], 'limits': {'gpu_or_ai_calls': 0, 'customer_records_touched': 0, 'deletions': 0}, 'not_proven': ['iPhone background suspension', 'real room reconstruction', 'legacy ticket migration', 'global budget contention']}
        (self.dir / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print('PASS: three real transfers, completion replay, app publication replay; sanitized receipt written', flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--live', action='store_true')
    p.add_argument('--private-directory', type=Path)
    p.add_argument('--negative-control', action='store_true')
    a = p.parse_args()
    check(png().startswith(b'\x89PNG'), 'synthetic PNG header')
    if a.negative_control:
        check(False, 'deliberate assertion control')
    check(a.live and a.private_directory, 'explicit live invocation required')
    proof = Proof(a.private_directory)
    try:
        proof.run()
    except Exception as e:
        # urllib exceptions may include capability URLs; emit only stage/type.
        print(f'FAIL: {proof.stage}; {type(e).__name__}; inspect protected state, no automatic retry', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as e:
        print(f'FAIL: preflight {type(e).__name__}', file=sys.stderr)
        sys.exit(1)
