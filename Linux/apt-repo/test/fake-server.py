#!/usr/bin/env python3
"""Throwaway stand-in for the apt server in CI: serves a directory over HTTP (like
`python3 -m http.server`) and also accepts POST /halltone-logs/<kind> uploads, appending
them to <dir>/../uploads.log so tests can see what the installer shipped."""
import os, sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

root, port = sys.argv[1], int(sys.argv[2])
log = os.path.join(os.path.dirname(os.path.abspath(root)), "uploads.log")


class H(SimpleHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(log, "ab") as f:
            f.write(f"##### POST {self.path} token={self.headers.get('X-Halltone-Log-Token')} host={self.headers.get('X-Halltone-Host')}\n".encode())
            f.write(body + b"\n")
        self.send_response(204); self.end_headers()


ThreadingHTTPServer(("127.0.0.1", port), partial(H, directory=root)).serve_forever()
