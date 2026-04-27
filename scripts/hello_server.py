import json
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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


if __name__ == "__main__":
    threading.Thread(target=render, daemon=True).start()
    Server(("", 4444), Handler).serve_forever()
