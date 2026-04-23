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
        global total_reqs
        with lock:
            total_reqs += 1
            req_times.append(time.monotonic())
        body = b"hello, world\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


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
