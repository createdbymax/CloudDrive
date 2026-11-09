#!/usr/bin/env python3
"""Loopback-only S3 contract fixture with independent Python SigV4 validation.

Synthetic credentials; no outbound network, saved connections or user payloads.
Control/report files belong to one disposable XCTest directory.
"""
import base64
import hashlib
import hmac
import http.server
import json
import pathlib
import re
import socket
import sys
import threading
import urllib.parse
import uuid
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape


class State:
    def __init__(self, root):
        self.root = root
        self.lock = threading.RLock()
        self.objects = {}
        self.uploads = {}
        self.events = []
        self.valid = self.invalid = 0
        self.revision = 0
        self.faults = {}
        self.used = set()

    def control(self):
        try:
            value = json.loads((self.root/'control.json').read_text())
        except (OSError, ValueError):
            return
        if value.get('revision') == self.revision:
            return
        self.revision = value.get('revision')
        self.faults = value
        if value.get('expireUploads'):
            self.uploads.clear()
        if value.get('removeChecksumKey') in self.objects:
            self.objects[value['removeChecksumKey']]['metadata'].pop('x-amz-meta-clouddrive-sha256', None)
        if value.get('dropPart'):
            for upload in self.uploads.values():
                upload['parts'].pop(int(value['dropPart']), None)

    def once(self, key):
        if not self.faults.get(key) or key in self.used:
            return False
        self.used.add(key)
        return True

    def save(self):
        value = {'events': self.events, 'validSignatures': self.valid, 'invalidSignatures': self.invalid,
                 'uploads': {key: sorted(upload['parts']) for key, upload in self.uploads.items()},
                 'objects': {key: {'size': len(item['data']), 'sha256': hashlib.sha256(item['data']).hexdigest(),
                                  'etag': item['etag'], 'metadata': item['metadata']} for key, item in self.objects.items()}}
        temporary = self.root/'report.tmp'
        temporary.write_text(json.dumps(value)); temporary.replace(self.root/'report.json')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def authenticated(self, body):
        match = re.fullmatch(r'AWS4-HMAC-SHA256 Credential=fixture-access/([^,]+), SignedHeaders=([^,]+), Signature=([0-9a-f]{64})', self.headers.get('Authorization', ''))
        if not match:
            return False
        scope, names, signature = match.groups()
        fields = scope.split('/')
        if len(fields) != 4 or fields[1:] != ['auto', 's3', 'aws4_request']:
            return False
        payload = hashlib.sha256(body).hexdigest()
        if payload != self.headers.get('x-amz-content-sha256'):
            return False
        parsed = urllib.parse.urlsplit(self.path)
        encode = lambda value: urllib.parse.quote(value, safe='-_.~')
        query = '&'.join(key+'='+value for key, value in sorted((encode(k), encode(v)) for k, v in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)))
        headers = names.split(';')
        if headers != sorted(headers) or 'host' not in headers or any(self.headers.get(key) is None for key in headers):
            return False
        canonical_headers = ''.join(key+':'+ ' '.join(self.headers[key].split())+'\n' for key in headers)
        canonical = '\n'.join([self.command, parsed.path, query, canonical_headers, names, payload])
        text = 'AWS4-HMAC-SHA256\n'+self.headers.get('x-amz-date', '')+'\n'+scope+'\n'+hashlib.sha256(canonical.encode()).hexdigest()
        signing = b'AWS4fixture-secret'
        for field in fields:
            signing = hmac.new(signing, field.encode(), hashlib.sha256).digest()
        return hmac.compare_digest(signature, hmac.new(signing, text.encode(), hashlib.sha256).hexdigest())

    def send(self, status, body=b'', headers=None, content_length=None):
        self.server.state.save()
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body) if content_length is None else content_length))
        self.end_headers()
        if self.command != 'HEAD' and body:
            self.wfile.write(body)

    def xml(self, status, body):
        self.send(status, body.encode(), {'Content-Type': 'application/xml'})

    def disconnect(self):
        self.server.state.save(); self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.connection.close()

    def metadata(self, value):
        return {**{'ETag': value['etag'], 'Last-Modified': 'Wed, 04 Nov 2026 12:00:00 GMT'}, **value['metadata']}

    def condition(self, old, copy=False):
        match = self.headers.get('cf-copy-destination-if-match' if copy else 'If-Match')
        absent = self.headers.get('cf-copy-destination-if-none-match' if copy else 'If-None-Match')
        return not ((match is not None and (old is None or old['etag'] != match)) or (absent == '*' and old is not None))

    def handle_request(self):
        state = self.server.state
        with state.lock:
            state.control()
            length = int(self.headers.get('Content-Length', '0'))
            if length < 0 or length > 68*1024*1024:
                self.send(413); return
            body = self.rfile.read(length)
            parsed = urllib.parse.urlsplit(self.path)
            key = urllib.parse.unquote(parsed.path.removeprefix('/fixture/')) if parsed.path.startswith('/fixture/') else None
            query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            state.events.append({'method': self.command, 'key': key, 'query': query,
                                 'ifMatch': self.headers.get('If-Match'), 'ifNoneMatch': self.headers.get('If-None-Match'),
                                 'copyDestinationIfNoneMatch': self.headers.get('cf-copy-destination-if-none-match')})
            if not self.authenticated(body):
                state.invalid += 1; self.xml(403, '<Error><Code>SignatureDoesNotMatch</Code></Error>'); return
            state.valid += 1
            if key and key.endswith('/redirect'):
                self.send(307, headers={'Location': f'http://127.0.0.1:{self.server.server_port}/fixture/prefix/redirect-target'}); return
            old = state.objects.get(key)
            if self.command == 'GET' and key is None:
                prefix = query.get('prefix', '')
                keys = sorted(value for value in state.objects if value.startswith(prefix))
                start = int(query.get('continuation-token', '0')); limit = int(query.get('max-keys', '1000')); page = keys[start:start+limit]
                if state.faults.get('listEscape'):
                    page = ['outside-prefix/forbidden']
                rows = ''.join('<Contents><Key>'+urllib.parse.quote(value, safe='')+'</Key><Size>'+str(len(state.objects[value]['data']) if value in state.objects else 1)+'</Size><ETag>'+escape(state.objects[value]['etag'] if value in state.objects else '"bad"')+'</ETag><LastModified>2026-11-04T12:00:00Z</LastModified></Contents>' for value in page)
                truncated = start+len(page) < len(keys)
                token = '<NextContinuationToken>'+str(start+len(page))+'</NextContinuationToken>' if truncated else ''
                self.xml(200, '<ListBucketResult><Name>fixture</Name><Prefix>'+urllib.parse.quote(prefix, safe='')+'</Prefix><EncodingType>url</EncodingType><IsTruncated>'+str(truncated).lower()+'</IsTruncated>'+token+rows+'</ListBucketResult>'); return
            if self.command == 'POST' and 'uploads' in query:
                identifier = uuid.uuid4().hex
                metadata = {k.lower(): v for k, v in self.headers.items() if k.lower().startswith('x-amz-meta-')}
                state.uploads[identifier] = {'key': key, 'parts': {}, 'metadata': metadata}
                if state.once('loseCreateResponse'):
                    self.disconnect(); return
                self.xml(200, '<InitiateMultipartUploadResult><Bucket>fixture</Bucket><Key>'+escape(key)+'</Key><UploadId>'+identifier+'</UploadId></InitiateMultipartUploadResult>'); return
            if 'uploadId' in query:
                upload = state.uploads.get(query['uploadId'])
                if upload is None or upload['key'] != key:
                    self.xml(404, '<Error><Code>NoSuchUpload</Code></Error>'); return
                if self.command == 'GET':
                    parts = sorted(upload['parts'])
                    marker = int(query.get('part-number-marker', '0')); selected = [n for n in parts if n > marker]
                    rows = ''.join('<Part><PartNumber>'+str(n)+'</PartNumber><ETag>'+escape(upload['parts'][n]['etag'])+'</ETag><Size>'+str(len(upload['parts'][n]['data']))+'</Size></Part>' for n in selected)
                    listed_key = 'prefix/another-upload' if state.faults.get('wrongPartsIdentity') else key
                    self.xml(200, '<ListPartsResult><Bucket>fixture</Bucket><Key>'+escape(listed_key)+'</Key><UploadId>'+query['uploadId']+'</UploadId><IsTruncated>false</IsTruncated>'+rows+'</ListPartsResult>'); return
                if self.command == 'PUT':
                    number = int(query['partNumber'])
                    if state.faults.get('failPartAlways') == number:
                        self.send(500); return
                    if state.faults.get('failPartBeforeOnce') == number and 'failed-part' not in state.used:
                        state.used.add('failed-part'); self.send(500); return
                    if base64.b64encode(hashlib.md5(body).digest()).decode() != self.headers.get('Content-MD5'):
                        self.send(400); return
                    upload['parts'][number] = {'data': body, 'etag': '"'+hashlib.md5(body).hexdigest()+'"'}
                    self.send(200, headers={'ETag': upload['parts'][number]['etag']}); return
                if self.command == 'POST':
                    try:
                        parts = [(int(part.findtext('PartNumber')), part.findtext('ETag')) for part in ET.fromstring(body).findall('Part')]
                    except (ValueError, ET.ParseError):
                        self.send(400); return
                    if any(number not in upload['parts'] or upload['parts'][number]['etag'] != tag for number, tag in parts):
                        self.xml(400, '<Error><Code>InvalidPart</Code></Error>'); return
                    data = b''.join(upload['parts'][number]['data'] for number, _ in parts)
                    etag = '"'+hashlib.md5(data).hexdigest()+'-'+str(len(parts))+'"'
                    state.objects[key] = {'data': data, 'etag': etag, 'metadata': upload['metadata']}
                    del state.uploads[query['uploadId']]
                    if state.once('loseCompleteResponse'):
                        self.disconnect(); return
                    self.xml(200, '<CompleteMultipartUploadResult><Bucket>fixture</Bucket><Key>'+escape(key)+'</Key><ETag>'+escape(etag)+'</ETag></CompleteMultipartUploadResult>'); return
            if self.command == 'HEAD':
                if old is None:
                    self.send(404); return
                reported_size = state.faults.get('headReportedSizes', {}).get(key, len(old['data']))
                self.send(200, headers=self.metadata(old), content_length=reported_size); return
            if self.command == 'GET':
                if old is None:
                    self.send(404); return
                if not self.condition(old):
                    self.send(412); return
                if not self.headers.get('Range'):
                    self.send(200, old['data'], self.metadata(old)); return
                match = re.fullmatch(r'bytes=(\d+)-(\d+)', self.headers.get('Range', ''))
                if not match:
                    self.send(400); return
                start, end = map(int, match.groups()); data = old['data'][start:end+1]
                headers = {**self.metadata(old), 'Content-Range': f'bytes {start}-{end}/{len(old["data"])}'}
                if key.endswith('/wrong-range'):
                    headers['Content-Range'] = f'bytes {start+1}-{end+1}/{len(old["data"])}'
                if key.endswith('/wrong-etag'):
                    headers['ETag'] = '"another-version"'
                if key.endswith('/truncated-range'):
                    data = data[:-1]
                self.send(200 if key.endswith('/ignored-range') else 206, data, headers); return
            if self.command == 'PUT':
                source = self.headers.get('x-amz-copy-source')
                if source:
                    if not self.condition(old, copy=True):
                        self.send(412); return
                    source = urllib.parse.unquote(source.removeprefix('/fixture/'))
                    original = state.objects.get(source)
                    if original is None:
                        self.send(404); return
                    if original['etag'] != self.headers.get('x-amz-copy-source-if-match'):
                        self.send(412); return
                    metadata = dict(original['metadata'])
                    directive = self.headers.get('x-amz-metadata-directive', 'COPY')
                    if directive not in ['COPY', 'REPLACE', 'MERGE']:
                        self.send(400); return
                    if directive == 'REPLACE':
                        metadata = {}
                    if directive in ['REPLACE', 'MERGE']:
                        metadata.update({k.lower(): v for k, v in self.headers.items() if k.lower().startswith('x-amz-meta-')})
                    state.objects[key] = {'data': original['data'], 'etag': original['etag'], 'metadata': metadata}
                    if state.once('loseCopyResponse'):
                        self.disconnect(); return
                    self.xml(200, '<CopyObjectResult><ETag>'+escape(original['etag'])+'</ETag><LastModified>2026-11-04T12:00:00Z</LastModified></CopyObjectResult>'); return
                if not self.condition(old):
                    self.send(412); return
                state.objects[key] = {'data': body, 'etag': '"'+hashlib.md5(body).hexdigest()+'"', 'metadata': {k.lower(): v for k, v in self.headers.items() if k.lower().startswith('x-amz-meta-')}}
                if state.once('losePutResponse'):
                    self.disconnect(); return
                self.send(200, headers={'ETag': state.objects[key]['etag']}); return
            if self.command == 'DELETE':
                if old is not None and not state.faults.get('ignoreDeleteConditions') and not self.condition(old):
                    self.send(412); return
                state.objects.pop(key, None); self.send(204); return
            self.send(405)

    do_HEAD = do_GET = do_PUT = do_POST = do_DELETE = handle_request


def main():
    root = pathlib.Path(sys.argv[1]); state = State(root)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.state = state
    # Readiness also promises that report.json is initialized for no-request
    # preflight tests. The HTTP handler starts only after this initialization.
    state.save(); (root/'port').write_text(str(server.server_port))
    server.serve_forever()


if __name__ == '__main__':
    main()
