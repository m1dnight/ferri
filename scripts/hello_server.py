import base64
import hashlib
import json
import os
import secrets
import struct
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_DOWNLOAD_MB = 1024
RANDOM_CHUNK_POOL = os.urandom(1024 * 1024)


def _random_chunk(n: int) -> bytes:
    if n <= len(RANDOM_CHUNK_POOL):
        start = secrets.randbelow(len(RANDOM_CHUNK_POOL) - n + 1)
        return RANDOM_CHUNK_POOL[start:start + n]
    return os.urandom(n)

active = 0
total_conns = 0
total_reqs = 0
client_disconnects = 0
req_times = deque()  # timestamps of recent requests, for req/s
lock = threading.Lock()

# Pre-built bodies so request handlers stay cheap.
LOREM = (
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
    "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. "
)
LOREM_BODY = (LOREM * 200).encode()           # ~22 KB
DOWNLOAD_BODY = (LOREM * 20_000).encode()     # ~2.2 MB
HOME_BODY = b"hello, world\n"
ABOUT_BODY = (
    b"<!doctype html><meta charset=utf-8>"
    b"<title>about</title>"
    b"<h1>about</h1>"
    b"<p>tiny test server for ferri load generation.</p>"
)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        global client_disconnects
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            with lock:
                client_disconnects += 1
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        global active, total_conns
        super().setup()
        with lock:
            active += 1
            total_conns += 1

    def finish(self):
        global active
        try:
            super().finish()
        finally:
            with lock:
                active -= 1

    def do_GET(self):
        self._count_request()
        path = self.path.split("?", 1)[0]

        if path == "/api/status":
            self._respond(200, _status_body(), "application/json")
            return

        if path == "/ws/time":
            self._serve_ws_time()
            return

        if path.startswith("/download/"):
            self._serve_random_download(path[len("/download/"):])
            return

        route = ROUTES.get(path)
        if route is None:
            self._respond(404, b"not found\n", "text/plain")
            return

        body, content_type, extra_headers = route
        self._respond(200, body, content_type, extra_headers)

    def do_POST(self):
        self._count_request()
        path = self.path.split("?", 1)[0]
        if path != "/echo":
            self._respond(404, b"not found\n", "text/plain")
            return
        body = self._read_body()
        self._respond(201, body, "application/octet-stream")

    def do_PUT(self):
        self._count_request()
        path = self.path.split("?", 1)[0]
        if path != "/echo":
            self._respond(404, b"not found\n", "text/plain")
            return
        body = self._read_body()
        self._respond(200, body, "application/octet-stream")

    def do_DELETE(self):
        self._count_request()
        path = self.path.split("?", 1)[0]
        if path != "/echo":
            self._respond(404, b"not found\n", "text/plain")
            return
        # 204 No Content: no body, no Content-Length per spec.
        self.send_response(204)
        self.end_headers()

    def _serve_random_download(self, raw_size):
        try:
            mb = int(raw_size)
        except ValueError:
            self._respond(400, b"size must be an integer\n", "text/plain")
            return
        if mb < 1 or mb > MAX_DOWNLOAD_MB:
            self._respond(
                400,
                f"size must be between 1 and {MAX_DOWNLOAD_MB}\n".encode(),
                "text/plain",
            )
            return

        total = mb * 1024 * 1024
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.send_header(
            "Content-Disposition",
            f'attachment; filename="random-{mb}mb.bin"',
        )
        self.end_headers()

        chunk_size = 64 * 1024
        remaining = total
        try:
            while remaining > 0:
                n = chunk_size if remaining >= chunk_size else remaining
                self.wfile.write(_random_chunk(n))
                remaining -= n
        except (BrokenPipeError, ConnectionResetError):
            return

    def _serve_ws_time(self):
        key = self.headers.get("Sec-WebSocket-Key")
        upgrade = (self.headers.get("Upgrade") or "").lower()
        if not key or upgrade != "websocket":
            self._respond(400, b"bad websocket request\n", "text/plain")
            return

        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()
        ).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()

        try:
            while True:
                payload = datetime.now(timezone.utc).isoformat().encode()
                self.wfile.write(_ws_text_frame(payload))
                self.wfile.flush()
                time.sleep(1.0)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def _count_request(self):
        global total_reqs
        with lock:
            total_reqs += 1
            req_times.append(time.monotonic())

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def _respond(self, status, body, content_type, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002 — overrides stdlib API
        del format, args  # silence access logs


def _ws_text_frame(payload: bytes) -> bytes:
    header = bytes([0x81])  # FIN=1, opcode=text
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < 65536:
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    return header + payload


def _status_body():
    with lock:
        payload = {
            "active": active,
            "total_conns": total_conns,
            "total_reqs": total_reqs,
            "client_disconnects": client_disconnects,
        }
    return json.dumps(payload).encode()


# (body, content_type, extra_headers)
ROUTES = {
    "/": (HOME_BODY, "text/plain", None),
    "/about": (ABOUT_BODY, "text/html; charset=utf-8", None),
    "/lorem": (LOREM_BODY, "text/plain; charset=utf-8", None),
    "/download.txt": (
        DOWNLOAD_BODY,
        "text/plain; charset=utf-8",
        {"Content-Disposition": 'attachment; filename="download.txt"'},
    ),
}


def render():
    while True:
        now = time.monotonic()
        with lock:
            while req_times and now - req_times[0] > 1.0:
                req_times.popleft()
            line = (
                f"active={active:>3}  conns={total_conns:>6}  "
                f"reqs={total_reqs:>7}  rps={len(req_times):>5}  "
                f"dropped={client_disconnects:>5}"
            )
        sys.stdout.write("\r\033[K" + line)
        sys.stdout.flush()
        time.sleep(0.1)


PORT = 4444

ENDPOINTS = [
    ("GET",  "/",            "plain text hello"),
    ("GET",  "/about",       "small html page"),
    ("GET",  "/lorem",       "~22 KB lorem ipsum"),
    ("GET",  "/download.txt", "~2.2 MB attachment"),
    ("GET",  "/download/{mb}", f"random binary of N MB (1..{MAX_DOWNLOAD_MB})"),
    ("GET",  "/api/status",  "json server stats"),
    ("GET",  "/ws/time",     "websocket: utc time, 1 msg/s"),
    ("POST", "/echo",        "echoes request body (201)"),
    ("PUT",  "/echo",        "echoes request body (200)"),
    ("DEL",  "/echo",        "no content (204)"),
]


def print_banner(port):
    print(f"hello_server listening on http://localhost:{port}")
    print("endpoints:")
    for method, path, desc in ENDPOINTS:
        print(f"  {method:<4} {path:<14}  {desc}")
    print()


if __name__ == "__main__":
    print_banner(PORT)
    threading.Thread(target=render, daemon=True).start()
    Server(("", PORT), Handler).serve_forever()
