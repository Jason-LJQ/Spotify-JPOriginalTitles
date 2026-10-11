#!/usr/bin/env python3
"""End-to-end check of the harness against the live extended-metadata endpoint.

Usage: AUTH='Bearer ...' e2e.py <workdir> <harness>
"""
import os
import subprocess
import sys
import urllib.request


def varint(n):
    out = b''
    while True:
        b = n & 0x7f
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def ld(field, payload):
    return varint(field << 3 | 2) + varint(len(payload)) + payload


def vi(field, n):
    return varint(field << 3) + varint(n)


def read_varint(b, i):
    shift = n = 0
    while True:
        c = b[i]
        i += 1
        n |= (c & 0x7f) << shift
        shift += 7
        if not c & 0x80:
            return n, i


def fields(b):
    i = 0
    while i < len(b):
        tag, i = read_varint(b, i)
        f, wt = tag >> 3, tag & 7
        if wt == 0:
            v, i = read_varint(b, i)
        elif wt == 2:
            ln, i = read_varint(b, i)
            v = b[i:i + ln]
            i += ln
        elif wt == 1:
            v = b[i:i + 8]
            i += 8
        elif wt == 5:
            v = b[i:i + 4]
            i += 4
        else:
            raise ValueError('wire type %d' % wt)
        yield f, v


def summarize(resp):
    out = {}
    for f, arr in fields(resp):
        if f != 2:
            continue
        kind = next((v for ff, v in fields(arr) if ff == 2), None)
        for ff, entry in fields(arr):
            if ff != 3:
                continue
            uri = next((v.decode() for f3, v in fields(entry) if f3 == 2), None)
            any_ = next((v for f3, v in fields(entry) if f3 == 3), b'')
            value = next((v for f4, v in fields(any_) if f4 == 2), b'')
            if kind == 178:
                d = {}
                for f5, v in fields(value):
                    if f5 == 2:
                        d['name'] = v.decode()
                    elif f5 == 4:
                        d['parent'] = [x.decode() for _, x in fields(v)]
                    elif f5 == 5:
                        d.setdefault('contributors', []).append([x.decode() for _, x in fields(v)])
                    elif f5 == 1:
                        d['type'] = v.decode()
                out.setdefault(uri, {})['identity'] = d
            else:
                out.setdefault(uri, {}).setdefault('kinds', []).append(kind)
    return out


work, harness = sys.argv[1], sys.argv[2]
entities = [
    ('spotify:track:2JQG6xNHej2Ml4XVSn9MXZ', [178]),
    ('spotify:track:3x2Sqs90LxndYgQDqmU51T', [178, 179]),
    ('spotify:track:0TSEoK4n55pnbr8pORV5lt', [178, 10]),
    ('spotify:track:5lk9YuQtv1EMp4POUG3LXR', [178]),
    ('spotify:track:4PTG3Z6ehGkBFwjybzWkR8', [178]),
    ('spotify:track:1VvmVtY3brxOXTqgIOPjef', [178]),
    ('spotify:track:09oouLCYjMag6OSW4AyEdY', [178, 10]),
    ('spotify:track:1jkaOiAQmqaI0NvTtR9W0H', [178, 10]),
    ('spotify:track:6R3Mltqkmy9c1ETQmw1nFB', [178]),
    ('spotify:track:1rbsxC5gFqFHArEbvhrCaD', [178]),
    ('spotify:album:4JXHvJxMSNhYga4DpW1Jgg', [178]),
]
# Client Accept-Language; the plugin only fetches originals itself when it does not start with zh
client_lang = os.environ.get('CLIENT_LANG', 'zh-Hans-US;q=1.00, en-US;q=0.50')
client_original = '1' if client_lang.lower().startswith('zh') else '0'
header = ld(1, b'US') + ld(2, b'premium')
body = ld(1, header) + b''.join(ld(2, ld(1, u.encode()) + b''.join(ld(2, vi(1, k)) for k in ks)) for u, ks in entities)
names = ('req.bin', 'req-aug.bin', 'added.txt', 'traits.txt', 'resp.bin', 'orig-req.bin', 'orig-resp.bin', 'resp-rw.bin')
paths = {k: os.path.join(work, k) for k in names}
open(paths['req.bin'], 'wb').write(body)


def run(*args):
    print(subprocess.run([harness, *args], capture_output=True, text=True).stdout.strip())


def post(src, dst, lang):
    req = urllib.request.Request(
        'https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata',
        data=open(src, 'rb').read(), method='POST',
        headers={'Authorization': os.environ['AUTH'], 'Content-Type': 'application/protobuf',
                 'Accept': 'application/protobuf', 'Accept-Language': lang})
    open(dst, 'wb').write(urllib.request.urlopen(req, timeout=30).read())


print('client language:', client_lang)
run('augment', paths['req.bin'], paths['req-aug.bin'], paths['added.txt'], paths['traits.txt'])
print('added:', open(paths['added.txt']).read().split())
post(paths['req-aug.bin'], paths['resp.bin'], client_lang)
run('originals', paths['resp.bin'], paths['traits.txt'], paths['req-aug.bin'], paths['orig-req.bin'],
    '0' if client_original == '1' else '1')
post(paths['orig-req.bin'], paths['orig-resp.bin'], 'zh-Hans')
run('rewrite', paths['resp.bin'], paths['added.txt'], paths['resp-rw.bin'], paths['orig-resp.bin'], client_original)

before = summarize(open(paths['resp.bin'], 'rb').read())
after = summarize(open(paths['resp-rw.bin'], 'rb').read())
def brief(d):
    i = (d or {}).get('identity', {})
    return '%s / %s / %s' % (i.get('name'), (i.get('parent') or [None])[0], [c[0] for c in i.get('contributors', [])])


for uri, _ in entities:
    print('==', uri, '\n  before:', brief(before.get(uri)), '\n  after: ', brief(after.get(uri)), (after.get(uri) or {}).get('kinds'))
