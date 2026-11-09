#!/usr/bin/env python3
"""Synthetic loopback S3 service for native move qualification. No real credentials."""
import base64
import datetime
import hashlib
import hmac
import http.server
import json
import threading
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape


def md5(data): return hashlib.md5(data).hexdigest()
def stamp(): return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, code, body=b'', headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items(): self.send_header(k, str(v))
        if not headers or 'Content-Length' not in headers: self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD' and body: self.wfile.write(body)
    def xml(self, body, code=200): self.send(code, body.encode(), {'Content-Type': 'application/xml'})
    def error(self, code, name): self.xml(f'<Error><Code>{name}</Code></Error>', code)
    def authenticated(self, body):
        auth = self.headers.get('Authorization', '')
        try:
            scheme, fields = auth.split(' ', 1)
            parts = dict(item.strip().split('=', 1) for item in fields.split(','))
            access, scope = parts['Credential'].split('/', 1)
            names = parts['SignedHeaders'].split(';')
            if scheme != 'AWS4-HMAC-SHA256' or access != 'fixture-access' or names != sorted(names) or 'host' not in names: return False
            parsed = urllib.parse.urlsplit(self.path)
            enc = lambda value: urllib.parse.quote(value, safe='-_.~')
            query = '&'.join(k+'='+v for k,v in sorted((enc(k),enc(v)) for k,v in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)))
            payload = self.headers.get('x-amz-content-sha256', hashlib.sha256(body).hexdigest())
            if payload != 'UNSIGNED-PAYLOAD' and payload != hashlib.sha256(body).hexdigest(): return False
            headers = ''.join(name+':'+ ' '.join(self.headers[name].split())+'\n' for name in names)
            # AWS canonical URI encodes literal percent signs a second time for S3 SDK requests only when sent that way.
            canonical = '\n'.join([self.command, parsed.path, query, headers, ';'.join(names), payload])
            value = '\n'.join(['AWS4-HMAC-SHA256', self.headers['x-amz-date'], scope, hashlib.sha256(canonical.encode()).hexdigest()])
            key = b'AWS4fixture-secret'
            for field in scope.split('/'): key = hmac.new(key, field.encode(), hashlib.sha256).digest()
            return hmac.compare_digest(hmac.new(key, value.encode(), hashlib.sha256).hexdigest(), parts['Signature'])
        except (ValueError, KeyError, TypeError): return False
    def handle_request(self):
        length = int(self.headers.get('Content-Length', 0))
        if length > 16*1024*1024: self.send(413); return
        body = self.rfile.read(length)
        if not self.authenticated(body): self.error(403, 'SignatureDoesNotMatch'); return
        s = self.server
        parsed = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
        key = urllib.parse.unquote(parsed.path.removeprefix('/fixture/'))
        # Delay outside the state lock so the fixture does not manufacture the
        # global metadata stall that the native regression is meant to detect.
        copy_source = self.headers.get('x-amz-copy-source')
        copy_key = urllib.parse.unquote(copy_source or '').removeprefix('/').removeprefix('fixture/')
        is_listing = parsed.path.rstrip('/') == '/fixture' and self.command == 'GET'
        metadata_key = q.get('prefix', '') if is_listing else key
        slow_metadata = self.command == 'HEAD' or is_listing
        matches = lambda value: any(value == prefix.rstrip('/') or value.startswith(prefix) for prefix in s.slow_prefixes)
        if slow_metadata and matches(metadata_key):
            s.metadata_entered.set()
            if is_listing and metadata_key.startswith('prefix/Slow/'):
                s.inventory_entered.set()
                if not s.inventory_release.wait(timeout=60): self.error(504, 'SyntheticInventoryPauseExpired'); return
            if s.metadata_delay: time.sleep(s.metadata_delay)
        if copy_source and (matches(key) or matches(copy_key)):
            s.copy_entered.set()
            if not s.copy_release.wait(timeout=60): self.error(504, 'SyntheticCopyPauseExpired'); return
            if s.copy_delay: time.sleep(s.copy_delay)
        with s.guard:
            if parsed.path.rstrip('/') == '/fixture' and self.command == 'HEAD': self.send(200); return
            if parsed.path.rstrip('/') == '/fixture' and self.command == 'GET':
                prefix, delimiter = q.get('prefix',''), q.get('delimiter','')
                objects, prefixes = [], set()
                for k, o in sorted(s.objects.items()):
                    if not k.startswith(prefix): continue
                    tail = k[len(prefix):]
                    if delimiter and delimiter in tail: prefixes.add(prefix+tail.split(delimiter)[0]+delimiter)
                    else: objects.append((k,o))
                entries = sorted([(k,False,o) for k,o in objects]+[(k,True,None) for k in prefixes])
                start = int(q.get('continuation-token','0')); page = entries[start:start+2]
                enc = lambda k: escape(urllib.parse.quote(k, safe='')) if q.get('encoding-type') == 'url' else escape(k)
                more = start+len(page)<len(entries)
                data = '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>fixture</Name><Prefix>'+enc(prefix)+'</Prefix><IsTruncated>'+str(more).lower()+'</IsTruncated>'
                if q.get('encoding-type') == 'url': data += '<EncodingType>url</EncodingType>'
                for k, directory, o in page:
                    if directory: data += '<CommonPrefixes><Prefix>'+enc(k)+'</Prefix></CommonPrefixes>'
                    else: data += f'<Contents><Key>{enc(k)}</Key><Size>{len(o["data"])}</Size><ETag>"{o["etag"]}"</ETag><LastModified>{o["time"]}</LastModified></Contents>'
                if more: data += f'<NextContinuationToken>{start+len(page)}</NextContinuationToken>'
                self.xml(data+'</ListBucketResult>');s.events.append({'operation':'list','key':prefix});return
            obj = s.objects.get(key)
            if self.command in ('HEAD','GET'):
                if obj is None: self.error(404,'NoSuchKey'); return
                headers = {'Content-Length': len(obj['data']), 'ETag': '"'+obj['etag']+'"', 'Last-Modified': 'Wed, 04 Nov 2026 12:00:00 GMT', 'Content-Type':'application/octet-stream'}
                headers.update(obj['metadata'])
                payload = obj['data']
                if self.command == 'GET':
                    s.events.append({'operation':'get','key':key})
                    if self.headers.get('Range'):
                        start,end = self.headers['Range'].removeprefix('bytes=').split('-'); start=int(start); end=int(end) if end else len(payload)-1
                        payload=payload[start:end+1];headers['Content-Range']=f'bytes {start}-{end}/{len(obj["data"])}';headers['Content-Length']=len(payload)
                        self.send(206,payload,headers);return
                self.send(200,payload,headers);return
            if self.command == 'DELETE':
                if q.get('uploadId'): s.uploads.pop(q['uploadId'],None);self.send(204);return
                if key==s.fail_delete: self.error(403,'AccessDenied');return
                s.objects.pop(key,None);s.events.append({'operation':'delete','key':key});self.send(204);return
            metadata = {k.lower():v for k,v in self.headers.items() if k.lower().startswith('x-amz-meta-')}
            if self.command == 'POST' and 'uploads' in q:
                uid=uuid.uuid4().hex;s.uploads[uid]={'key':key,'metadata':metadata,'parts':{}}
                self.xml(f'<InitiateMultipartUploadResult><Bucket>fixture</Bucket><Key>{escape(key)}</Key><UploadId>{uid}</UploadId></InitiateMultipartUploadResult>');return
            if self.command == 'POST' and 'uploadId' in q:
                upload=s.uploads[q['uploadId']];payload=b''.join(upload['parts'][int(next(c.text for c in p if c.tag.endswith('PartNumber')))] for p in ET.fromstring(body))
                etag=md5(b''.join(hashlib.md5(v).digest() for _,v in sorted(upload['parts'].items())))+'-'+str(len(upload['parts']))
                s.objects[key]={'data':payload,'etag':etag,'metadata':upload['metadata'],'time':stamp()};s.uploads.pop(q['uploadId'])
                self.xml(f'<CompleteMultipartUploadResult><Location>http://127.0.0.1/fixture/{escape(key)}</Location><Bucket>fixture</Bucket><Key>{escape(key)}</Key><ETag>"{etag}"</ETag></CompleteMultipartUploadResult>');return
            if self.command == 'PUT':
                copy = self.headers.get('x-amz-copy-source')
                if copy:
                    src=urllib.parse.unquote(copy).removeprefix('/').removeprefix('fixture/')
                    if src not in s.objects: self.error(404,'NoSuchKey');return
                    original=s.objects[src];payload=original['data']
                    if self.headers.get('x-amz-copy-source-if-match') not in (None, '"'+original['etag']+'"'):
                        self.error(412,'PreconditionFailed');return
                    if key == s.inject_copy_collision:
                        s.inject_copy_collision = None
                        competing = b'concurrent unrelated owner'
                        s.objects[key] = {'data':competing,'etag':md5(competing),'metadata':{},'time':stamp()}
                    if self.headers.get('cf-copy-destination-if-none-match')=='*' and key in s.objects:
                        self.error(412,'PreconditionFailed');return
                    if q.get('uploadId'):
                        lo,hi=self.headers['x-amz-copy-source-range'].removeprefix('bytes=').split('-');payload=payload[int(lo):int(hi)+1]
                        s.uploads[q['uploadId']]['parts'][int(q['partNumber'])]=payload
                        s.events.append({'operation':'multipartCopy','key':key});self.xml(f'<CopyPartResult><LastModified>{stamp()}</LastModified><ETag>"{md5(payload)}"</ETag></CopyPartResult>');return
                    directive = self.headers.get('x-amz-metadata-directive')
                    if directive == 'MERGE':
                        if (not self.headers.get('x-amz-copy-source-if-match') or
                            self.headers.get('cf-copy-destination-if-none-match') != '*'):
                            self.error(400,'MissingMoveConditions');return
                        metadata = original['metadata'] | metadata
                    elif directive != 'REPLACE':
                        metadata=original['metadata'].copy()
                    s.events.append({'operation':'copy','key':key})
                else: payload=body
                s.objects[key]={'data':payload,'etag':md5(payload),'metadata':metadata,'time':stamp()}
                if copy: self.xml(f'<CopyObjectResult><LastModified>{stamp()}</LastModified><ETag>"{md5(payload)}"</ETag></CopyObjectResult>')
                else: self.send(200, headers={'ETag':'"'+md5(payload)+'"'})
                return
            self.error(501,'NotImplemented')
    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = handle_request


def start(source, root, *, metadata_delay=0, copy_delay=0, slow_prefixes=()):
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    server.daemon_threads=True;server.guard=threading.RLock();server.objects={};server.events=[];server.uploads={};server.fail_delete=None;server.inject_copy_collision=None
    server.metadata_delay=metadata_delay;server.copy_delay=copy_delay;server.slow_prefixes=tuple(slow_prefixes)
    server.metadata_entered=threading.Event();server.copy_entered=threading.Event();server.copy_release=threading.Event();server.copy_release.set()
    server.inventory_entered=threading.Event();server.inventory_release=threading.Event();server.inventory_release.set()
    for p in source.rglob('*'):
        key='prefix/'+str(p.relative_to(source))
        data=p.read_bytes() if p.is_file() else b''
        if p.is_dir(): key+='/'
        server.objects[key]={'data':data,'etag':md5(data),'metadata':{'x-amz-meta-mtime':'1793793600'},'time':stamp()}
    threading.Thread(target=server.serve_forever,daemon=True).start()
    return server
