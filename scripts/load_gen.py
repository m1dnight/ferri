"""Tiny load generator for the hello_server (or anything serving the same paths).

Examples:
    python scripts/load_gen.py http://localhost:4444
    python scripts/load_gen.py https://your-tunnel.example.com -c 16 -d 60
    python scripts/load_gen.py http://localhost:4444 --only-download
    python scripts/load_gen.py http://localhost:4444 --methods post,put --upload-size 256KB
"""

import argparse
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from urllib.parse import urljoin

# (method, path). Pairs that need a request body are inferred from the method.
DEFAULT_OPS = [
    ("GET", "/"),
    ("GET", "/about"),
    ("GET", "/lorem"),
    ("GET", "/api/status"),
    ("GET", "/download.txt"),
    ("POST", "/echo"),
    ("PUT", "/echo"),
    ("DELETE", "/echo"),
]
BODY_METHODS = {"POST", "PUT"}
DOWNLOAD_PATH = "/download.txt"

SIZE_SUFFIXES = [
    ("GIB", 1_073_741_824),
    ("MIB", 1_048_576),
    ("KIB", 1_024),
    ("GB", 1_000_000_000),
    ("MB", 1_000_000),
    ("KB", 1_000),
    ("G", 1_000_000_000),
    ("M", 1_000_000),
    ("K", 1_000),
    ("B", 1),
]


def parse_size(s):
    s = s.strip().upper()
    for suffix, mult in SIZE_SUFFIXES:
        if s.endswith(suffix):
            return int(float(s[: -len(suffix)]) * mult)
    return int(s)


def fetch(method, url, body, timeout):
    req = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={"User-Agent": "ferri-loadgen/1"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        # Read full body so download bytes actually flow through.
        data = resp.read()
        return resp.status, len(data)


def worker(stop_at, base_url, ops, upload_body, timeout, stats, stats_lock):
    while time.monotonic() < stop_at:
        method, path = random.choice(ops)
        url = urljoin(base_url, path)
        body = upload_body if method in BODY_METHODS else None
        tx = len(body) if body else 0

        t0 = time.monotonic()
        try:
            status, rx = fetch(method, url, body, timeout)
            elapsed = time.monotonic() - t0
            with stats_lock:
                stats["ok"] += 1
                stats["tx_bytes"] += tx
                stats["rx_bytes"] += rx
                stats["latency_total"] += elapsed
                stats["status"][status] += 1
                stats["by_method"][method] += 1
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            with stats_lock:
                stats["err"] += 1
                stats["errors"][type(exc).__name__] += 1


def render(stats, stats_lock, stop_event, started_at):
    while not stop_event.is_set():
        with stats_lock:
            ok = stats["ok"]
            err = stats["err"]
            tx = stats["tx_bytes"]
            rx = stats["rx_bytes"]
            lat_total = stats["latency_total"]
        elapsed = max(time.monotonic() - started_at, 1e-6)
        rps = ok / elapsed
        tx_mbps = (tx * 8) / 1_000_000 / elapsed
        rx_mbps = (rx * 8) / 1_000_000 / elapsed
        avg_ms = (lat_total / ok * 1000) if ok else 0.0
        line = (
            f"ok={ok:>6}  err={err:>4}  rps={rps:>6.1f}  "
            f"avg={avg_ms:>5.1f}ms  tx={tx_mbps:>6.2f}Mbps  rx={rx_mbps:>6.2f}Mbps"
        )
        sys.stdout.write("\r\033[K" + line)
        sys.stdout.flush()
        time.sleep(0.1)


def select_ops(args):
    if args.only_download:
        return [("GET", DOWNLOAD_PATH)]
    ops = DEFAULT_OPS
    if args.methods:
        wanted = {m.strip().upper() for m in args.methods.split(",") if m.strip()}
        ops = [(m, p) for (m, p) in ops if m in wanted]
        if not ops:
            sys.exit(f"no ops match --methods={args.methods}")
    return ops


def main():
    parser = argparse.ArgumentParser(description="Tiny load generator.")
    parser.add_argument("url", help="Base URL, e.g. http://localhost:4444")
    parser.add_argument("--concurrency", "-c", type=int, default=8)
    parser.add_argument("--duration", "-d", type=float, default=30.0,
                        help="Seconds to run (default 30).")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--methods",
                        help="Comma-separated method filter (e.g. get,post). "
                             "Default: all methods.")
    parser.add_argument("--upload-size", default="16KB",
                        help="Body size for POST/PUT, e.g. 64KB, 1MB (default 16KB).")
    parser.add_argument("--only-download", action="store_true",
                        help="Shortcut: hit only GET /download.txt.")
    args = parser.parse_args()

    ops = select_ops(args)
    upload_size = parse_size(args.upload_size)
    upload_body = b"x" * upload_size if any(m in BODY_METHODS for m, _ in ops) else b""

    base_url = args.url if args.url.endswith("/") else args.url + "/"

    stats = {
        "ok": 0,
        "err": 0,
        "tx_bytes": 0,
        "rx_bytes": 0,
        "latency_total": 0.0,
        "status": Counter(),
        "errors": Counter(),
        "by_method": Counter(),
    }
    stats_lock = threading.Lock()
    stop_event = threading.Event()

    started_at = time.monotonic()
    stop_at = started_at + args.duration

    workers = [
        threading.Thread(
            target=worker,
            args=(stop_at, base_url, ops, upload_body, args.timeout, stats, stats_lock),
            daemon=True,
        )
        for _ in range(args.concurrency)
    ]
    renderer = threading.Thread(
        target=render, args=(stats, stats_lock, stop_event, started_at), daemon=True
    )

    print(f"target      : {base_url}")
    print(f"ops         : {ops}")
    print(f"upload size : {upload_size:,} B (used by POST/PUT)")
    print(f"workers     : {args.concurrency}   duration: {args.duration}s")
    print()
    renderer.start()
    for w in workers:
        w.start()
    try:
        for w in workers:
            w.join()
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        renderer.join(timeout=0.5)

    elapsed = time.monotonic() - started_at
    sys.stdout.write("\n\n")
    print(f"finished in {elapsed:.1f}s")
    print(f"  ok       : {stats['ok']}")
    print(f"  errors   : {stats['err']}")
    print(f"  tx bytes : {stats['tx_bytes']:,}")
    print(f"  rx bytes : {stats['rx_bytes']:,}")
    if stats["ok"]:
        print(f"  avg      : {stats['latency_total']/stats['ok']*1000:.1f} ms")
        print(f"  rps      : {stats['ok']/elapsed:.1f}")
        print(f"  tx       : {(stats['tx_bytes']*8)/1_000_000/elapsed:.2f} Mbps")
        print(f"  rx       : {(stats['rx_bytes']*8)/1_000_000/elapsed:.2f} Mbps")
    if stats["by_method"]:
        print(f"  by method: {dict(stats['by_method'])}")
    if stats["status"]:
        print(f"  status   : {dict(stats['status'])}")
    if stats["errors"]:
        print(f"  err kinds: {dict(stats['errors'])}")


if __name__ == "__main__":
    main()
