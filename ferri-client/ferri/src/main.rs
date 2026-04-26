mod protocol;
mod proxy;
mod tui;

use std::env;
use std::future::poll_fn;

use anyhow::Context;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_util::compat::{Compat, FuturesAsyncReadCompatExt, TokioAsyncReadCompatExt};
use yamux::{Config, Connection, Mode, Stream};

use protocol::{ClientMessage, ServerMessage};
use proxy::proxy_stream;
use tui::LogSink;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let port = parse_args();

    // Channel: everything that wants to print does so by sending a String here;
    // the TUI drains it into the on-screen log buffer.
    let (log_tx, log_rx) = mpsc::unbounded_channel::<String>();

    // Connect to the Ferri server and create a yamux session over it.
    let stream = TcpStream::connect(ferri_endpoint()).await?;
    let mut yamux_session = Connection::new(stream.compat(), Config::default(), Mode::Client);

    // Open the control stream (stream 1).
    let control_stream = poll_fn(|cx| yamux_session.poll_new_outbound(cx)).await?;
    let control_stream = control_stream.compat();

    // Drive inbound streams in a background task — each is one visitor request.
    spawn_inbound_driver(yamux_session, port, log_tx.clone());

    // Register a subdomain.
    let url = register(control_stream).await?;
    let _ = log_tx.send(format!("Tunnel live at {url} -> localhost:{port}"));

    // The TUI takes over the terminal; returns when the user presses q / Ctrl-C.
    tui::run(log_rx).await
}

/// Continuously listens for new incoming connections on the yamux stream from
/// the Ferri server. Each new stream is a new connection to the http endpoint.
fn spawn_inbound_driver(mut session: Connection<Compat<TcpStream>>, port: u16, log: LogSink) {
    tokio::spawn(async move {
        loop {
            match poll_fn(|cx| session.poll_next_inbound(cx)).await {
                Some(Ok(stream)) => {
                    let log = log.clone();
                    tokio::spawn(async move {
                        if let Err(e) = proxy_stream(stream.compat(), port, log.clone()).await {
                            let _ = log.send(format!("proxy error: {e}"));
                        }
                    });
                }
                Some(Err(e)) => {
                    let _ = log.send(format!("yamux error: {e}"));
                    break;
                }
                None => break,
            }
        }
    });
}

/// Register with the Ferri server to obtain a new URL.
async fn register(mut control_stream: Compat<Stream>) -> anyhow::Result<String> {
    let frame = protocol::encode(&ClientMessage::Register);
    control_stream.write_all(&frame).await?;

    let mut buf = vec![0u8; 1024];
    let n = control_stream.read(&mut buf).await?;
    let (response, _) =
        protocol::decode(&buf[..n]).context("incomplete or missing response from server")?;

    match response {
        ServerMessage::Error { reason } => Err(anyhow::anyhow!("registration failed: {reason}")),
        ServerMessage::Registered { url, .. } => Ok(url),
    }
}

/// Parse the CLI arguments. Exits with code 2 on misuse.
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

/// Generates the Ferri endpoint. If the binary is not run in release mode it
/// will use a local instance of ferri instead of the hosted version.
fn ferri_endpoint() -> &'static str {
    if cfg!(debug_assertions) {
        "localhost:59595"
    } else {
        "ferri.run:59595"
    }
}
