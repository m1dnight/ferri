# Ferri Tunnel Protocol

In this document, I will write out what the protocol for a Ferri client should
be to work with the Ferri server.

The Ferri tunnel protocol defines the shape of the messages being sent over
streams between the client and server. The protocol allows a client ot register
a stream of data.


## Requesting DNS

When the client starts (e.g., `ferri 4000`), the client establishes a connection
to the Ferri server and opens up a yamux session.

Inside that session a first control stream is opened, which serves as the
communication channel to send back and forth control commands.

Over the control channel, the client requests a DNS entry.

```json
{"type": "register"}
```

The server then responds with either an acknowledgement, or a reject.

```json
{"type": "registered", "subdomain": "x77d", "url": "https://x77d.ferri.dev"}
```

Or, if the registration was rejected.

```json
{"type": "error", "reason": "not today"}
```