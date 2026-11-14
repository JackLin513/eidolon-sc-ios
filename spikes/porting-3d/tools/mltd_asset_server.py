#!/usr/bin/env python3
"""Tiny on-demand asset server: resolves MLTD asset name -> CDN file name.

GET /asset/<asset_name>  -> serves the bundle if present locally (404 otherwise,
                            so the client can fall back to the official CDN)
GET /health              -> {"ready": n}
"""
import os, json, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(BASE, "files")
MANIFEST = os.path.join(BASE, "manifest.tsv")

MAP = {}
with open(MANIFEST) as f:
    next(f)
    for line in f:
        p = line.rstrip("\n").split("\t")
        if len(p) == 4:
            MAP[p[0]] = (p[1], p[2], int(p[3]))

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):  # keep the log quiet
        pass
    def _send(self, code, body=b"", ctype="application/octet-stream", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/health":
            body = json.dumps({"ready": len(MAP)}).encode()
            return self._send(200, body, "application/json")
        if u.path.startswith("/asset/"):
            name = urllib.parse.unquote(u.path[len("/asset/"):])
            ent = MAP.get(name)
            if not ent:
                return self._send(404, b'{"error":"unknown asset"}', "application/json")
            cdn, sha, size = ent
            path = os.path.join(FILES, cdn)
            if not os.path.exists(path):
                return self._send(404, b'{"error":"not cached","cdn":"%s"}' % cdn.encode(), "application/json")
            body = open(path, "rb").read()
            return self._send(200, body, "application/octet-stream",
                              {"X-Asset-Sha256": sha, "X-Asset-Name": name,
                               "X-Storage": "nas"})
        return self._send(404, b"not found", "text/plain")

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 2872), H).serve_forever()
