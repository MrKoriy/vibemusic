#!/usr/bin/env python3
"""Локальный HTTP-сервер с поддержкой Range для тестирования StreamHub."""
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

if len(sys.argv) < 2:
    print("usage: test_server.py <file> [port]")
    sys.exit(2)

path = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 8123

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            self.send_response(404)
            self.end_headers()
            return
        total = len(data)
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            start_s, _, end_s = rng[6:].partition("-")
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else total - 1
            end = min(end, total - 1)
            if start > end or start >= total:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.end_headers()
                return
            chunk = data[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("Content-Length", str(len(chunk)))
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.wfile.write(chunk)
        else:
            self.send_response(200)
            self.send_header("Content-Length", str(total))
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("[upstream] " + (fmt % args) + "\n")

print(f"serving {path} on http://127.0.0.1:{port}", flush=True)
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
