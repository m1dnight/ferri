//! Per-stream proxy: visitor yamux stream <-> local TCP socket.
//!
//! The yamux→tcp direction runs through an HTTP/1.1 framer that emits a log
//! line for *every* request seen on the connection (not just the first), even
//! under keep-alive. The tcp→yamux direction is just byte forwarding.

use anyhow::Context;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_util::compat::Compat;
use yamux::Stream;

use crate::tui::LogSink;

/// Proxy a single yamux stream (one visitor connection) to the local port.
pub async fn proxy_stream(stream: Compat<Stream>, port: u16, log: LogSink) -> anyhow::Result<()> {
    let tcp = TcpStream::connect(("127.0.0.1", port))
        .await
        .with_context(|| format!("dial localhost:{port}"))?;

    let (yamux_r, yamux_w) = tokio::io::split(stream);
    let (tcp_r, tcp_w) = tokio::io::split(tcp);

    let up = tokio::spawn(forward_with_logging(yamux_r, tcp_w, log.clone()));
    let down = tokio::spawn(forward(tcp_r, yamux_w));

    // Wait for both directions to finish (each does its own half-close on EOF).
    let _ = tokio::join!(up, down);
    Ok(())
}

/// Visitor → local: forward bytes while feeding them through the HTTP framer
/// so we can log each request as it arrives.
async fn forward_with_logging<R, W>(
    mut reader: R,
    mut writer: W,
    log: LogSink,
) -> std::io::Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut framer = Framer::new();
    let mut buf = vec![0u8; 8 * 1024];
    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        framer.feed(&buf[..n], &log);
        writer.write_all(&buf[..n]).await?;
    }
    let _ = writer.shutdown().await;
    Ok(())
}

/// Local → visitor: dumb byte pipe, no parsing.
async fn forward<R, W>(mut reader: R, mut writer: W) -> std::io::Result<u64>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let n = tokio::io::copy(&mut reader, &mut writer).await?;
    let _ = writer.shutdown().await;
    Ok(n)
}

// ---------------------------------------------------------------------------
// HTTP/1.1 framer
//
// State machine that walks a stream of request bytes and emits a log line
// (method + path) per request. Handles back-to-back requests on a keep-alive
// connection by tracking Content-Length to skip request bodies.
//
// Bails into a `Skipped` terminal state on:
//   - Transfer-Encoding: chunked (we don't parse chunked encoding here).
//   - Malformed headers.
//   - Header buffer >8 KB.
//
// Once `Skipped`, bytes still flow through unchanged; we just stop logging.
// ---------------------------------------------------------------------------

const MAX_HEADER_BYTES: usize = 8 * 1024;
const MAX_HEADERS: usize = 32;

struct Framer {
    buf: Vec<u8>,
    state: FramerState,
}

enum FramerState {
    Headers,
    Body { remaining: usize },
    Skipped,
}

impl Framer {
    fn new() -> Self {
        Self {
            buf: Vec::with_capacity(2048),
            state: FramerState::Headers,
        }
    }

    fn feed(&mut self, mut bytes: &[u8], log: &LogSink) {
        while !bytes.is_empty() {
            let consumed = self.step(bytes, log);
            if consumed == 0 {
                // Terminal state (Skipped) — caller still forwards remaining bytes,
                // we just don't process them.
                return;
            }
            bytes = &bytes[consumed..];
        }
    }

    fn step(&mut self, bytes: &[u8], log: &LogSink) -> usize {
        match self.state {
            FramerState::Skipped => 0,

            FramerState::Body { remaining } => {
                let n = bytes.len().min(remaining);
                let new_remaining = remaining - n;
                self.state = if new_remaining == 0 {
                    FramerState::Headers
                } else {
                    FramerState::Body {
                        remaining: new_remaining,
                    }
                };
                n
            }

            FramerState::Headers => {
                let prev_len = self.buf.len();
                self.buf.extend_from_slice(bytes);

                let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
                let mut req = httparse::Request::new(&mut headers);

                match req.parse(&self.buf) {
                    Ok(httparse::Status::Complete(header_size)) => {
                        let method = req.method.unwrap_or("?");
                        let path = req.path.unwrap_or("?");
                        let _ = log.send(format!("{:>4} {}", method, path));

                        let body_len = body_len_from_headers(&headers);

                        // How much of the *current* `bytes` slice did headers cover?
                        let consumed_from_input = header_size.saturating_sub(prev_len);

                        self.buf.clear();
                        self.state = match body_len {
                            Some(len) if len > 0 => FramerState::Body { remaining: len },
                            Some(_) => FramerState::Headers,
                            None => FramerState::Skipped, // chunked / unknown framing
                        };
                        consumed_from_input
                    }

                    Ok(httparse::Status::Partial) => {
                        if self.buf.len() > MAX_HEADER_BYTES {
                            self.state = FramerState::Skipped;
                        }
                        bytes.len()
                    }

                    Err(_) => {
                        self.state = FramerState::Skipped;
                        0
                    }
                }
            }
        }
    }
}

/// Per RFC 7230 §3.3: Transfer-Encoding wins over Content-Length. We only
/// understand non-chunked traffic — chunked returns None so the caller bails.
fn body_len_from_headers(headers: &[httparse::Header]) -> Option<usize> {
    let mut chunked = false;
    let mut content_length: Option<usize> = None;

    for h in headers.iter().take_while(|h| !h.name.is_empty()) {
        if h.name.eq_ignore_ascii_case("transfer-encoding") {
            if let Ok(v) = std::str::from_utf8(h.value)
                && v.split(',')
                    .any(|s| s.trim().eq_ignore_ascii_case("chunked"))
            {
                chunked = true;
            }
        } else if h.name.eq_ignore_ascii_case("content-length")
            && let Ok(v) = std::str::from_utf8(h.value)
        {
            content_length = v.trim().parse().ok();
        }
    }

    if chunked {
        None
    } else {
        Some(content_length.unwrap_or(0))
    }
}
