# Ferri Control Protocol

The control protocol runs **on top of yamux** between the Rust client and the
Elixir server. It defines how tunnels are established and how visitor traffic
flows.

## Connections

```
Rust client ──── TCP:4433 ────► Elixir server
                 │
                 └─ yamux session
                      ├─ stream 1 (client-opened, control)
                      ├─ stream 2 (server-opened, visitor)
                      ├─ stream 4 (server-opened, visitor)
                      └─ ...
```

- **Port 4433**: Rust clients connect here and establish a yamux session.
- **Port 443**: Browsers connect here. The server extracts the subdomain from
  the `Host` header and routes traffic to the matching yamux session.

## Stream conventions

| Stream    | Opened by | Purpose |
|-----------|-----------|---------|
| Stream 1  | Client    | Control channel — registration, errors, keepalive |
| Stream 2+ | Server    | One per visitor connection — raw HTTP bytes proxied bidirectionally |

The client always opens exactly **one** stream immediately after connecting:
the control stream. All other streams are opened by the server when a visitor
arrives.

## Control stream (stream 1)

Messages are **length-prefixed JSON**: 4 bytes big-endian length, then a JSON
object of that many bytes.

```
┌──────────┬──────────────────────┐
│ len (4B) │ JSON payload (len B) │
└──────────┴──────────────────────┘
```

### Message types

#### REGISTER (client → server)

Sent immediately after opening the control stream. Claims a subdomain.

```json
{"type": "register", "subdomain": "x7k2"}
```

- If `subdomain` is `""` or omitted, the server assigns a random one.
- If `subdomain` is taken, the server responds with an ERROR.

#### REGISTERED (server → client)

Confirms the tunnel is live.

```json
{"type": "registered", "subdomain": "x7k2", "url": "https://x7k2.ferri.dev"}
```

After this message, the client should expect incoming visitor streams.

#### ERROR (server → client)

Sent when registration (or any control operation) fails.

```json
{"type": "error", "reason": "subdomain_taken"}
```

Known reasons:
- `"subdomain_taken"` — another client already owns this subdomain
- `"invalid_subdomain"` — contains invalid characters or is reserved
- `"rate_limited"` — too many connections from this IP

The server MAY close the control stream (and session) after sending an error,
or allow the client to retry with a different subdomain.

#### PING / PONG (bidirectional)

Optional application-level keepalive on top of yamux's built-in ping.

```json
{"type": "ping"}
{"type": "pong"}
```

> **Open question**: Is this needed? Yamux already has ping/pong at the
> transport level. This would only be useful if we want the control protocol
> to detect liveness independently of yamux, or if we want to measure
> application-level latency.

## Visitor streams (server-opened)

When a browser connects to `https://x7k2.ferri.dev`:

1. Server accepts the TLS connection.
2. Server reads enough to extract `Host: x7k2.ferri.dev` from the HTTP
   request headers.
3. Server looks up `x7k2` in the tunnel registry → finds the yamux session.
4. Server opens a new stream on that session (even ID).
5. Server forwards the **raw HTTP bytes** (including the request line and
   headers it already read) into the yamux stream.
6. Client accepts the stream, dials `localhost:PORT`, and proxies bytes
   bidirectionally between the yamux stream and the local TCP connection.
7. When either side closes, the yamux stream is half-closed with FIN.

```
Browser ←TCP→ Elixir ←yamux stream→ Rust client ←TCP→ localhost:4000
              (raw HTTP bytes, no re-encoding)
```

**No additional framing** is needed on visitor streams. The yamux stream IS
the tunnel — bytes go in one end and come out the other.

### Edge cases

- **Client disconnects**: Server detects session termination, returns 502 to
  any in-flight visitors, removes subdomain from registry.
- **Visitor disconnects**: Server closes the yamux stream (FIN). Client sees
  the stream close, closes the local TCP connection.
- **Local server not running**: Client fails to dial localhost:PORT, sends RST
  on the yamux stream. Server returns 502 to the visitor.
- **Slow client**: Yamux flow control handles backpressure. The server's stream
  send window fills up, the server stops reading from the visitor socket, TCP
  backpressure propagates to the browser.

## Lifecycle

```
1. Rust client dials TCP:4433
2. Yamux session established (client mode)
3. Client opens stream 1 (control)
4. Client sends: {"type": "register", "subdomain": "x7k2"}
5. Server validates, inserts into registry
6. Server sends: {"type": "registered", "subdomain": "x7k2", "url": "https://x7k2.ferri.dev"}
7. Client prints: "Tunnel live at https://x7k2.ferri.dev → localhost:4000"

--- visitor arrives ---

8.  Browser GETs https://x7k2.ferri.dev/hello
9.  Server opens yamux stream 2 to client
10. Server writes raw HTTP request bytes into stream 2
11. Client accepts stream 2, dials localhost:4000
12. Client proxies bytes: stream 2 ↔ localhost:4000
13. Response flows back through stream 2 to server to browser
14. Stream 2 closed (FIN from both sides)
```

## Open questions

1. **Should the server send any metadata on visitor streams?** For example, a
   small header with the visitor's IP before the raw HTTP bytes. This would let
   the local server see the real client IP. But it adds complexity — the Rust
   client would need to strip/inject an `X-Forwarded-For` header instead.

2. **Multiple subdomains per client?** Currently one REGISTER per session. We
   could allow multiple REGISTER messages to claim multiple subdomains on the
   same session, each routing to a different local port.

3. **Authentication?** The REGISTER message could include a token. Or we could
   use mutual TLS on port 4433. Or just leave it open for self-hosted use.

4. **Reconnection?** If the Rust client reconnects, should it be able to
   reclaim the same subdomain? A session token or API key would enable this.
