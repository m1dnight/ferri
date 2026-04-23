mod protocol;

use std::env;
use std::future::poll_fn;

use anyhow::Context;
use futures::AsyncReadExt;
use futures::AsyncWriteExt;
use tokio::io::AsyncWriteExt;
use tokio::io::AsyncWriteExt;
use tokio::io::AsyncWriteExt;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio_util::compat::FuturesAsyncReadCompatExt;
use tokio_util::compat::TokioAsyncReadCompatExt;
use yamux::{Config, Connection, Mode, Stream};

use protocol::{ClientMessage, ServerMessage};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Parse the port to connect to locally.
    let port = parse_args();

    // Connect to the Ferri server over TCP, and then create a Yamux session.
    let stream = TcpStream::connect("localhost:59595").await?;
    let mut yamux_session = Connection::new(stream.compat(), Config::default(), Mode::Client);

    // Open the control stream (stream 1) on the yamux session.
    let control_stream = poll_fn(|cx| yamux_session.poll_new_outbound(cx)).await?;

    // Poll for new incoming streams. Each new incoming stream is a request sent
    // over from the Ferri server and represents an HTTP client.
    //
    // Notice we have not registered yet, this is just to make sure we catch a
    // connection as soon as we are registered.
    tokio::spawn(async move {
        loop {
            match poll_fn(|cx| yamux_session.poll_next_inbound(cx)).await {
                // New client connected
                Some(Ok(stream)) => {
                    tokio::spawn(proxy_stream(stream, port));
                }
                // An error occurred, abort.
                Some(Err(e)) => {
                    eprintln!("Yamux error: {e}");
                    break;
                }
                None => break,
            }
        }
    });

    // Try and register a new subdomain
    let subdomain = register(control_stream).await?;
    let url = format_url(&subdomain);
    println!("Tunnel live at {url} -> localhost:{port}");

    // Keep the connection alive
    futures::future::pending::<()>().await;

    Ok(())
}

/// Parse the CLI arguments.
/// Exits with code 2 to signal misused command
fn parse_args() -> u16 {
    let Some(raw) = env::args().nth(1) else {
        eprintln!("usage: ferri <port>");
        std::process::exit(2);
    };
    raw.parse().unwrap_or_else(|_| {
        eprintln!("usage: ferri <port>  (port must be 1-65535)");
        std::process::exit(2);
    })
}

/// Formats the session name into the full URL.
/// In debugging this is localhost, otherwise ferri.
fn format_url(subdomain: &str) -> String {
    if cfg!(debug_assertions) {
        format!("http://{subdomain}.localhost:8080")
    } else {
        format!("https://{subdomain}.ferri.dev")
    }
}

// Send REGISTER to Ferri to obtain a new DNS
async fn register(mut control_stream: Stream) -> anyhow::Result<String> {
    // Create REGISTER payload
    let frame = protocol::encode(&ClientMessage::Register);
    control_stream.write_all(&frame).await?;

    // Read REGISTERED / ERROR response
    let mut buf = vec![0u8; 1024];
    let n = control_stream.read(&mut buf).await?;
    let (response, _) =
        protocol::decode(&buf[..n]).context("incomplete or missing response from server")?;

    match response {
        ServerMessage::Error { reason } => Err(anyhow::anyhow!("registration failed: {reason}")),
        ServerMessage::Registered { subdomain, .. } => Ok(subdomain),
    }
}

/// Proxy a single yamux stream (one visitor request) to the local port.
///
/// Dials `localhost:port`, then shuttles bytes in both directions until either
/// side closes. A failed local dial is logged and the stream is dropped, which
/// closes it on the server side.
async fn proxy_stream(mut stream: yamux::Stream, port: u16) -> anyhow::Result<()> {
    // Connect to the local port via ipv4.
    let mut tcp = TcpStream::connect(("127.0.0.1", port))
        .await
        .with_context(|| format!("dial localhost:{port}"))?;

    // peak at the stream to see the first incoming webrequest
    let (request_line, bytes) = peek_request_line(&mut stream).await?;

    // Write out all the bytes we peeked
    // Create compatible stream for Tokio AsyncRead
    let mut stream = stream.compat();

    // Create a bidirectional connection between the stream and the tcp socket
    let (to_local, to_remote) = tokio::io::copy_bidirectional(&mut tcp, &mut stream).await?;

    // If we reach this point, the stream has been terminated either on the TCP side or the Ferri side.
    eprintln!("proxy done: local<-{to_local}B  local->{to_remote}B");
    Ok(())
}

struct RequestLine {
    method: String,
    path: String,
}

async fn peek_request_line(reader: &mut yamux::Stream) -> anyhow::Result<(RequestLine, Vec<u8>)> {
    let mut buffer = Vec::with_capacity(1024);
    let mut tmp = [0u8; 512];

    loop {
        let bytes_read = reader.read(&mut tmp).await?;

        if bytes_read == 0 {
            anyhow::bail!("stream ended before request line");
        }

        // Copy the read bytes into the buffer
        buffer.extend_from_slice(&tmp[..bytes_read]);

        // Try and parse the request to figure out its path and method.
        if let Some(end) = buffer.windows(2).position(|w| w == b"\r\n") {
            let line =
                std::str::from_utf8(&buffer[..end]).context("request line is not valid UTF-8")?;
            let mut parts = line.splitn(3, ' ');
            let method = parts.next().context("missing method")?.to_string();
            let path = parts.next().context("missing path")?.to_string();
            return Ok((RequestLine { method, path }, buffer));
        }

        if buffer.len() > 8 * 1024 {
            anyhow::bail!("request line exceeds 8 KB");
        }
    }
}
