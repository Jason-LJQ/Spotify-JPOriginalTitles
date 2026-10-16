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
            active += 1
            maximum_active = max(maximum_active, active)
        try:
            time.sleep(0.02)
            if self.path == '/http-failure' or (self.path.startswith('/client-failure') and not client):
                self.send_response(503)
                self.end_headers()
                return
            groups = defaultdict(list)
            selected = queries[:-1] if self.path == '/partial' else queries
            for kind, uri in selected:
                payload = catalog.get((kind, uri))
                if kind == 9 and payload is None:
                    payload = ld(2, b'Catalog release') + ld(35, uri.encode())
                elif kind == 8:
                    name = 'Artist' if self.headers.get('Accept-Language') != 'ja' else '検証アーティスト'
                    payload = ld(2, name.encode())
                assert payload is not None, (kind, uri)
                status = 500 if self.path == '/entry-failure' else 200
                entry = ld(1, vi(1, status)) + ld(2, uri.encode()) + ld(3, ld(2, payload))
                groups[kind].append(ld(3, entry))
            data = b''.join(ld(2, vi(2, kind) + b''.join(entries)) for kind, entries in groups.items())
            if self.path == '/malformed':
                data = b'\xff'
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-protobuf')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            with lock:
                records.append({'path': self.path, 'entities': len({uri for _, uri in queries}),
                                'language': self.headers.get('Accept-Language'),
                                'kinds': sorted({kind for kind, _ in queries})})
        finally:
            with lock:
                active -= 1

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', str(raw_path), str(request_path)],
                        capture_output=True, text=True, timeout=120)
server.shutdown()
text = result.stdout + result.stderr
print(text, end='')
output.write_text(text)
output.with_suffix('.requests.json').write_text(json.dumps({'requests': records, 'maximumConcurrent': maximum_active}, indent=2))
assert result.returncode == 0, result.returncode
assert max(record['entities'] for record in records) <= 256
assert maximum_active <= 3
print(f'PASS server: {len(records)} requests, at most 256 entities per request, concurrency {maximum_active}/3')
