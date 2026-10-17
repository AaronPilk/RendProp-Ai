#!/usr/bin/env python3
"""Execute real incoming-URL policy against a closed browser boundary."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-public-website-links-'))
out.mkdir(parents=True, exist_ok=True)
deep = root/'apps/ios/Rendprop/DeepLink/DeepLink.swift'
app = root/'apps/ios/Rendprop/RendpropApp.swift'
test = root/'apps/ios/tests/PublicWebsiteLinkTests.swift'
paths = [deep, app, test, Path(__file__).resolve()]
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
bound = hashes()
source = app.read_text()
anchor = '@MainActor private func enqueueIncomingURL(_ url: URL)'
start = source.index(anchor); opening = source.index('{', start); end = opening + 1; depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}'); end += 1
body = source[start:end].replace('@MainActor private func', 'func', 1)
assert body.index('DeepLink.publicWebsiteURL(url)') < body.index('DeepLink.parse(url)')
assert 'UIApplication.shared.open(website)' in body
interfaces = '''import Foundation
@MainActor final class UIApplication {
 static let shared = UIApplication(); var opened: [URL] = []
 func open(_ url: URL) { opened.append(url) }
}
@MainActor final class IncomingWebsiteFixture {
 var incomingQueue = NativeIncomingQueue()
'''

def run(name, actual_deep, actual_body, should_pass):
    target = out/(name+'.swift')
    target.write_text(actual_deep+'\n'+interfaces+actual_body+'\n}\n'+test.read_text())
    binary = out/name
    compiled = subprocess.run(['swiftc', '-parse-as-library', str(target), '-o', str(binary)], capture_output=True, text=True)
    (out/(name+'-compile.log')).write_text(compiled.stdout+compiled.stderr)
    if compiled.returncode: raise RuntimeError('Compile failed: '+name)
    ran = subprocess.run([str(binary)], capture_output=True, text=True)
    (out/(name+'-run.log')).write_text(ran.stdout+ran.stderr)
    if (ran.returncode == 0) != should_pass: raise RuntimeError('Semantic gate failed: '+name)
    return {'name': name, 'exit': ran.returncode, 'expected_pass': should_pass}

original = deep.read_text()
results = [run('actual', original, body, True)]
needle = 'if let website = DeepLink.publicWebsiteURL(url)'
assert body.count(needle) == 1
results.append(run('disabled-browser-handoff', original, body.replace(needle, 'if let website: URL = nil'), False))
needle = 'hosts.contains((url.host ?? "").lowercased()),'
assert original.count(needle) == 1
results.append(run('foreign-host-browser-leak', original.replace(needle, 'true,'), body, False))
needle = 'url.user == nil, url.password == nil,'
assert original.count(needle) == 2
results.append(run('credential-url-leak', original.replace(needle, ''), body, False))
assert hashes() == bound, 'Source changed during executable proof'
(out/'receipt.json').write_text(json.dumps({'status':'passed','sources':bound,'results':results,
    'scope':'actual DeepLink plus AppRoot enqueue function, closed UIKit/browser boundary; no physical UI or network'}, indent=2)+'\n')
print('Public website link gate passed: actual plus 3 rejected compiled controls')
