#!/usr/bin/env python3
"""Read-only inventory wire fixture with independently verified SigV4. Loopback only."""
import http.server
import importlib.util
import pathlib
import sys
import urllib.parse
import xml.sax.saxutils

spec = importlib.util.spec_from_file_location('multipart_fixture', pathlib.Path(__file__).with_name('multipart-s3-fixture.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class Handler(base.Handler):
    def send(self, status, body=b'', headers=None):
        if self.command == 'HEAD' and headers and 'Content-Length' in headers:
            self.server.state.save()
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.end_headers()
        else:
            super().send(status, body, headers)

    def handle_request(self):
        with self.server.state.lock:
            state = self.server.state
            parsed = urllib.parse.urlsplit(self.path)
            query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
            state.events.append({'method': self.command, 'path': parsed.path, 'query': query})
            if not self.authenticated(b''):
                state.invalid += 1
                self.send(403)
                return
            state.valid += 1
            if self.command == 'HEAD':
                if parsed.path.endswith('/denied'):
                    self.send(403)
                elif parsed.path.endswith('/missing'):
                    self.send(404)
                elif parsed.path.endswith('/redirect'):
                    self.send(302, headers={'Location': '/fixture/prefix/redirect-target'})
                elif parsed.path.endswith('/malformed-head'):
                    self.send(200)
                else:
                    self.send(200, headers={'Content-Length': '42', 'ETag': '"opaque"', 'Last-Modified': 'Thu, 01 Jan 2026 00:00:00 GMT'})
                return
            if self.command != 'GET' or parsed.path != '/fixture' or query.get('list-type') != '2':
                self.send(405)
                return
            if not query.get('prefix', '').startswith('prefix/') or query.get('encoding-type') != 'url' or query.get('max-keys') != '1000':
                self.send(400)
                return
            scope = query['prefix']
            token = query.get('continuation-token')
            if token not in (None, 'opaque+/% token'):
                self.send(400)
                return
            keys = ['prefix/Album/Vócals +%2F.wav', 'prefix/Cafe\u0301.wav'] if token is None else ['prefix/final.mov']
            if scope != 'prefix/':
                keys = [key for key in ['prefix/Album/Vócals +%2F.wav', 'prefix/Cafe\u0301.wav', 'prefix/final.mov'] if key.startswith(scope)]
            enc = lambda s: urllib.parse.quote(s, safe='')
            esc = xml.sax.saxutils.escape
            body = '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>fixture</Name><Prefix>' + enc(scope) + '</Prefix><EncodingType>url</EncodingType>'
            body += '<IsTruncated>' + ('true' if token is None and scope == 'prefix/' else 'false') + '</IsTruncated>'
            if token is None and scope == 'prefix/':
                body += '<NextContinuationToken>opaque+/% token</NextContinuationToken>'
            for key in keys:
                body += '<Contents><Key>' + enc(key) + '</Key><Size>42</Size><ETag>&quot;opaque&quot;</ETag><LastModified>2026-01-01T00:00:00.123Z</LastModified></Contents>'
            body += '</ListBucketResult>'
            self.xml(200, body)

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = handle_request


if __name__ == '__main__':
    folder = pathlib.Path(sys.argv[1])
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.state = base.State(folder / 'report.json')
    server.state.save()
    (folder / 'port').write_text(str(server.server_port))
    server.serve_forever(poll_interval=0.05)
