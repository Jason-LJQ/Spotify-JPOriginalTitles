"""Run asynchronous lookup tests with private catalog fixtures on loopback only."""
import json
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading
import time

namespace = {}
source = (Path(__file__).parent / 'e2e.py').read_text()
exec(source[:source.index('work, harness =')], namespace)
fields, ld, vi = (namespace[key] for key in ['fields', 'ld', 'vi'])
binary, raw_path, request_path, fixtures, output = map(Path, sys.argv[1:])
catalog = {}

def collect(raw):
    for number, array in fields(raw):
        if number != 2:
            continue
        kind = dict(fields(array)).get(2)
        for field, entry in fields(array):
            if field != 3:
                continue
            data = dict(fields(entry))
            if dict(fields(data.get(1, b''))).get(1) != 200:
                continue
            catalog[(kind, data[2].decode())] = dict(fields(data[3]))[2]

collect(raw_path.read_bytes())
for path in fixtures.glob('JPTPath-*-lookup-response.bin'):
    collect(path.read_bytes())
# The original client response supplies IdentityTrait for the delegate test.
for path in fixtures.glob('JPTPath-*-server-response.bin'):
    collect(path.read_bytes())
records = []
lock = threading.Lock()
active = maximum_active = 0
attempts = defaultdict(int)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global active, maximum_active
        assert not self.headers.get('Authorization') and not self.headers.get('Cookie')
        body = self.rfile.read(int(self.headers['Content-Length']))
        queries = []
        for number, entity in fields(body):
            if number != 2:
                continue
            parts = list(fields(entity))
            uri = next(value.decode() for field, value in parts if field == 1)
            for field, query in parts:
                if field == 2:
                    queries.append((dict(fields(query))[1], uri))
        client = any(kind == 178 for kind, _ in queries)
        with lock:
            mode = self.path.removesuffix('/extended-metadata/v0/extended-metadata')
            if mode != '/timeout':
                active += 1
                maximum_active = max(maximum_active, active)
            counts_key = (mode, self.headers.get('Accept-Language'))
            attempts[counts_key] += 1
            attempt = attempts[counts_key]
            records.append({'path': self.path, 'entities': len({uri for _, uri in queries}),
                            'uris': [uri for _, uri in queries], 'client': client,
                            'language': self.headers.get('Accept-Language'), 'kinds': sorted({kind for kind, _ in queries})})
        try:
            time.sleep(0.02)
            status = None
            if not client:
                if mode in ['/429','/401','/403'] or mode.startswith(('/client-429','/client-401','/client-403')):
                    status = int(mode.split('-')[1]) if mode.startswith('/client-') else int(mode[1:])
                elif mode in ['/first-500', '/client-first-500'] and attempt == 1:
                    status = 500
                elif mode == '/over-64' and len(queries) > 64:
                    status = 500
                elif mode == '/poison' and any(uri.endswith('0000000000000000000001') for _, uri in queries):
                    status = 500
                elif mode == '/timeout':
                    time.sleep(0.5)
            if status:
                self.send_response(status); self.end_headers(); return
            if (client and mode == '/client-original-503'):
                self.send_response(503); self.end_headers(); self.wfile.write(b'official-error'); return
            if (client and mode == '/client-original-empty'):
                self.send_response(200); self.end_headers(); return
            if self.path in ['/http-failure', '/strict-exhausted'] or (self.path.startswith('/client-failure') and not client):
                self.send_response(503)
                self.end_headers()
                return
            groups = defaultdict(list)
            selected = queries[:-1] if self.path == '/partial' or (mode == '/missing-once' and attempt == 1) else queries
            for kind, uri in selected:
                payload = catalog.get((kind, uri))
                if kind == 9 and payload is None:
                    payload = ld(2, b'Catalog release') + ld(35, uri.encode())
                elif kind == 8:
                    name = 'Artist' if self.headers.get('Accept-Language') != 'ja' else '検証アーティスト'
                    payload = ld(2, name.encode())
                if payload is None and kind == 10 and uri.rsplit(':',1)[-1].isdigit():
                    payload = ld(2, b'OMGkawaiiAngel')
                if payload is None and kind == 178 and uri.rsplit(':',1)[-1].isdigit():
                    payload = ld(2, b'OMGkawaiiAngel')
                if payload is None and mode == '/client-album-404' and kind == 10:
                    payload = b''
                assert payload is not None, (kind, uri)
                status = 500 if self.path == '/entry-failure' else 200
                if not client and mode.startswith('/client-absence-'):
                    status = int(mode[-3:])
                if not client and mode == '/client-empty':
                    payload = b''
                if not client and mode == '/entry-once' and attempt == 1 and (kind, uri) == queries[0]:
                    status = 500
                if not client and mode == '/entry-parse-once' and attempt == 1 and (kind, uri) == queries[0]:
                    payload = b'\xff'
                if mode == '/client-album-404':
                    if kind == 9:
                        payload = ld(2, '原版专辑'.encode()) + ld(11, ld(3, ld(1, bytes.fromhex('11111111111111111111111111111111'))))
                    elif kind == 10 and uri != 'spotify:track:1wXrIFdqheifq4ETjCpqoi':
                        status = 404
                if client and mode == '/client-nested-malformed' and kind == 10:
                    payload = b'\xff'
                entry = ld(1, vi(1, status)) + ld(2, uri.encode()) + ld(3, ld(2, payload))
                groups[kind].append(ld(3, entry))
                if mode == '/duplicate-once' and attempt == 1 and (kind, uri) == queries[0]:
                    groups[kind].append(ld(3, entry))
            data = b''.join(ld(2, vi(2, kind) + b''.join(entries)) for kind, entries in groups.items())
            if self.path == '/malformed' or (client and mode == '/client-malformed'):
                data = b'\xff'
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-protobuf')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock:
                if mode != '/timeout':
                    active -= 1

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', str(raw_path), str(request_path)],
                        capture_output=True, text=True, timeout=180)
server.shutdown()
text = result.stdout + result.stderr
print(text, end='')
output.write_text(text)
output.with_suffix('.requests.json').write_text(json.dumps({'requests': records, 'maximumConcurrent': maximum_active}, indent=2))
assert result.returncode == 0, result.returncode
assert max(record['entities'] for record in records) <= 256
assert maximum_active <= 3
print(f'PASS server: {len(records)} requests, at most 256 entities per request, concurrency {maximum_active}/3')

if binary.stem == 'retry_policy_test':
    def sizes(path):
        return sorted(r['entities'] for r in records if r['path'] == path)
    expected = {'/over-64': [256,64,64,64,64], '/poison': [256,64,64,64,64,16,16,16,16],
                '/first-500': [256,64,64,64,64], '/http-failure': [256,64,64,64,64],
                '/timeout': [256,64,64,64,64], '/strict-exhausted': [256,64,64,64,64], '/malformed': [256,64,64,64,64],
                '/missing-once': [256,1], '/entry-once': [256,1], '/entry-parse-once': [256,1], '/duplicate-once': [256,1],
                '/429': [256], '/401': [256], '/403': [256]}
    for path, wanted in expected.items():
        assert sizes(path) == sorted(wanted), (path, sizes(path), wanted)
        print('PASS request sizes', path, sizes(path))
    for code in [429,401,403]:
        found = [r for r in records if r['path'] == f'/client-{code}/extended-metadata/v0/extended-metadata' and not r['client']]
        assert len(found) == 2, (code, len(found))
        print('PASS immediate client stop', code, 'one lookup per strict mode setting')
    print('PASS retry request accounting; timeout server handlers excluded from live-transport concurrency')

    for mode in ['original-503','original-empty','nested-malformed']:
        lookups=[r for r in records if r['path']==f'/client-{mode}/extended-metadata/v0/extended-metadata' and not r['client']]
        assert not lookups, (mode, lookups)
        print('PASS original response bypass/preflight',mode)
    absent=[r for r in records if r['path']=='/client-album-404/extended-metadata/v0/extended-metadata' and not r['client']]
    assert any(r['kinds']==[9] for r in absent) and any(r['kinds']==[10] for r in absent)
    print('PASS complete album absence exercised through real stage requests')
