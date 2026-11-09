#!/usr/bin/env python3
"""Disposable loopback-only S3 wire fixture. Synthetic credentials only, no network egress.

Independently verifies SigV4 with Python's hashlib/hmac instead of trusting the
Swift signer. Not a general S3 emulator; only used by MultipartTransportTests.
"""
import base64
import hashlib
import hmac
import http.server
import json
import pathlib
import re
import sys
import threading
import urllib.parse
import xml.etree.ElementTree as ET


class State:
    def __init__(self, report):
        self.report = report
        self.uploads = {}
        self.objects = {}
        self.lock = threading.RLock()
        self.events = []
        self.valid = 0
        self.invalid = 0

    def save(self):
        self.report.write_text(json.dumps({
            'validSignatures': self.valid, 'invalidSignatures': self.invalid,
            'events': self.events,
            'objects': {key: {'size': len(value['data']), 'sha256': hashlib.sha256(value['data']).hexdigest()}
                        for key, value in self.objects.items()},
        }))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send(self, status, body=b'', headers=None):
        self.server.state.save()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD' and body:
            self.wfile.write(body)

    def xml(self, status, body):
        self.send(status, body.encode(), {'Content-Type': 'application/xml'})

    def authenticated(self, body):
        authorization = self.headers.get('Authorization', '')
        match = re.fullmatch(r'AWS4-HMAC-SHA256 Credential=fixture-access/([^,]+), SignedHeaders=([^,]+), Signature=([0-9a-f]{64})', authorization)
        if not match:
            return False
        scope, names, signature = match.groups()
        fields = scope.split('/')
        if len(fields) != 4 or fields[1:] != ['auto', 's3', 'aws4_request']:
            return False
        payload = hashlib.sha256(body).hexdigest()
        if self.headers.get('x-amz-content-sha256') != payload:
            return False
        split = urllib.parse.urlsplit(self.path)
        encode = lambda value: urllib.parse.quote(value, safe='-_.~')
        query = '&'.join(key + '=' + value for key, value in sorted(
            (encode(key), encode(value)) for key, value in urllib.parse.parse_qsl(split.query, keep_blank_values=True)))
        header_names = names.split(';')
        if header_names != sorted(header_names) or 'host' not in header_names:
            return False
        if any(self.headers.get(name) is None for name in header_names):
            return False
        canonical_headers = ''.join(name + ':' + ' '.join(self.headers[name].split()) + '\n' for name in header_names)
        canonical = '\n'.join([self.command, split.path, query, canonical_headers, names, payload])
        to_sign = 'AWS4-HMAC-SHA256\n' + self.headers['x-amz-date'] + '\n' + scope + '\n' + hashlib.sha256(canonical.encode()).hexdigest()
        signing_key = b'AWS4fixture-secret'
        for field in fields:
            signing_key = hmac.new(signing_key, field.encode(), hashlib.sha256).digest()
        expected = hmac.new(signing_key, to_sign.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(signature, expected)

    def handle_request(self):
        state = self.server.state
        with state.lock:
            length = int(self.headers.get('Content-Length', '0'))
            if length > 16 * 1024 * 1024:
                self.send(413)
                return
            body = self.rfile.read(length)
            parsed = urllib.parse.urlsplit(self.path)
            key = urllib.parse.unquote(parsed.path.removeprefix('/fixture/'))
            query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            event = {'method': self.command, 'key': key, 'query': query}
            state.events.append(event)
            if not self.authenticated(body):
                state.invalid += 1
                self.xml(403, '<Error><Code>SignatureDoesNotMatch</Code></Error>')
                return
            state.valid += 1
            if key.endswith('/redirect'):
                self.send(307, headers={'Location': '/fixture/prefix/redirect-target'})
                return
            if self.command == 'HEAD':
                if key.endswith('/malformed-head'):
                    self.send(200)
                elif key not in state.objects:
                    self.send(404)
                else:
                    obj = state.objects[key]
                    if key.endswith('/compressed-head') and self.headers.get('Accept-Encoding') != 'identity':
                        self.send_response(200)
                        self.send_header('Content-Encoding', 'gzip')
                        self.send_header('ETag', 'W/"' + obj['etag'] + '"')
                        self.send_header('x-amz-meta-clouddrive-upload-id', obj['job'])
                        self.end_headers()
                        return
                    # HEAD advertises object length, never emits payload.
                    self.send(200, obj['data'], {'ETag': '"' + obj['etag'] + '"',
                                              'x-amz-meta-clouddrive-upload-id': obj['job']})
                return
            if self.command == 'POST' and 'uploads' in query:
                if key.endswith('/create-failure'):
                    self.xml(503, '<Error><Code>ServiceUnavailable</Code></Error>')
                    return
                uid = 'fixture-session-' + str(len(state.uploads) + 1)
                state.uploads[uid] = {'key': key, 'job': self.headers.get('x-amz-meta-clouddrive-upload-id', ''), 'parts': {}}
                self.xml(200, '<InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><UploadId>' + uid + '</UploadId></InitiateMultipartUploadResult>')
                return
            if self.command == 'PUT' and 'uploadId' not in query:
                if body and self.headers.get('Content-MD5') != base64.b64encode(hashlib.md5(body).digest()).decode():
                    self.xml(400, '<Error><Code>BadDigest</Code></Error>')
                    return
                if self.headers.get('If-None-Match') != '*':
                    self.send(400)
                    return
                if key in state.objects:
                    self.send(412)
                    return
                state.objects[key] = {'data': body, 'etag': hashlib.md5(body).hexdigest(),
                                      'job': self.headers.get('x-amz-meta-clouddrive-upload-id', '')}
                self.send(200, headers={'ETag': '"' + state.objects[key]['etag'] + '"'})
                return
            if self.command == 'GET' and key.endswith('/malformed-list'):
                self.xml(200, '<ListPartsResult><IsTruncated>false</IsTruncated><Part><ETag>bad</ETag><Size>1</Size></Part></ListPartsResult>')
                return
            if self.command == 'GET' and key.endswith('/loop-pagination'):
                self.xml(200, '<ListPartsResult><IsTruncated>true</IsTruncated><NextPartNumberMarker>0</NextPartNumberMarker></ListPartsResult>')
                return
            if self.command == 'GET' and key.endswith('/oversized'):
                self.xml(200, '<ListPartsResult>' + ' ' * 2_100_000 + '</ListPartsResult>')
                return
            uid = query.get('uploadId')
            upload = state.uploads.get(uid)
            if upload is None or key.endswith('/expired'):
                self.xml(404, '<Error><Code>NoSuchUpload</Code></Error>')
                return
            if upload['key'] != key:
                self.send(400)
                return
            if self.command == 'GET':
                marker = int(query.get('part-number-marker', '0'))
                numbers = sorted(n for n in upload['parts'] if n > marker)
                page = numbers[:1]  # Deliberately force pagination with only a few small parts.
                more = len(numbers) > len(page)
                parts = ''.join('<Part><PartNumber>' + str(n) + '</PartNumber><ETag>&quot;' +
                                hashlib.md5(upload['parts'][n]).hexdigest() + '&quot;</ETag><Size>' +
                                str(len(upload['parts'][n])) + '</Size></Part>' for n in page)
                self.xml(200, '<ListPartsResult><IsTruncated>' + str(more).lower() + '</IsTruncated>' +
                         ('<NextPartNumberMarker>' + str(page[-1]) + '</NextPartNumberMarker>' if more else '') + parts + '</ListPartsResult>')
                return
            if self.command == 'PUT':
                if key.endswith('/retry-part') and sum(e['method'] == 'PUT' and e['key'] == key for e in state.events) == 1:
                    self.xml(503, '<Error><Code>SlowDown</Code></Error>')
                    return
                digest = hashlib.md5(body).digest()
                if self.headers.get('Content-MD5') != base64.b64encode(digest).decode():
                    self.xml(400, '<Error><Code>BadDigest</Code></Error>')
                    return
                upload['parts'][int(query['partNumber'])] = body
                tag = '00000000000000000000000000000000' if key.endswith('/bad-etag') else digest.hex()
                self.send(200, headers={'ETag': '"' + tag + '"'})
                return
            if self.command == 'POST':
                if key.endswith('/embedded-error'):
                    self.xml(200, '<Error><Code>InternalError</Code><Message>Synthetic completion failure</Message></Error>')
                    return
                request = ET.fromstring(body)
                numbers = [int(part.findtext('PartNumber')) for part in request.findall('Part')]
                if numbers != sorted(numbers) or len(set(numbers)) != len(numbers):
                    self.send(400)
                    return
                for part in request.findall('Part'):
                    n = int(part.findtext('PartNumber'))
                    if part.findtext('ETag').strip('"') != hashlib.md5(upload['parts'][n]).hexdigest():
                        self.send(400)
                        return
                full = b''.join(upload['parts'][n] for n in numbers)
                tag = hashlib.md5(b''.join(hashlib.md5(upload['parts'][n]).digest() for n in numbers)).hexdigest() + '-' + str(len(numbers))
                state.objects[key] = {'data': full, 'etag': tag, 'job': upload['job']}
                del state.uploads[uid]
                self.xml(200, '<CompleteMultipartUploadResult><ETag>&quot;' + tag + '&quot;</ETag></CompleteMultipartUploadResult>')
                return
            if self.command == 'DELETE':
                del state.uploads[uid]
                self.send(204)
                return
            self.send(405)

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = handle_request


if __name__ == '__main__':
    folder = pathlib.Path(sys.argv[1])
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.state = State(folder / 'report.json')
    server.state.save()
    (folder / 'port').write_text(str(server.server_port))
    server.serve_forever(poll_interval=0.05)
