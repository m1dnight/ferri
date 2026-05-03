mod protocol;
mod proxy;
mod tui;

use std::future::poll_fn;

use anyhow::Context;
use clap::Parser;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_util::compat::{Compat, FuturesAsyncReadCompatExt, TokioAsyncReadCompatExt};
use yamux::{Config, Connection, Mode, Stream};

use protocol::{ClientMessage, ServerMessage};
use proxy::proxy_stream;
use tui::LogSink;

/// Parsed command-line arguments for the Ferri client.
#[derive(Parser)]
#[command(name = "ferri", about = "Ferri tunnel client")]
struct FerriArgs {
    /// Local TCP port to forward incoming tunnel traffic to.
    #[arg(value_parser = clap::value_parser!(u16).range(1..))]
    port: u16,
    /// Address (host:port) of the Ferri server to connect to.
    #[arg(
        long = "remote",
        default_value = "ferri.run:59595",
        value_parser = parse_remote_host,
    )]
    remote_host: String,
}

/// Validate `--remote` is `host:port` with a non-empty host and a port in 1..=65535.
fn parse_remote_host(s: &str) -> Result<String, String> {
    let (host, port) = s
        .rsplit_once(':')
        .ok_or_else(|| format!("`{s}` must be in host:port form"))?;
    if host.is_empty() {
        return Err(format!("`{s}` is missing a host"));
    }
    let port: u16 = port
        .parse()
        .map_err(|_| format!("`{port}` is not a valid port"))?;
    if port == 0 {
        return Err("port must be 1-65535".into());
    }
    Ok(s.to_string())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let FerriArgs { port, remote_host } = FerriArgs::parse();

    // Channel: everything that wants to print does so by sending a String here;
    // the TUI drains it into the on-screen log buffer.
    let (log_tx, log_rx) = mpsc::unbounded_channel::<String>();

    // Connect to the Ferri server and create a yamux session over it.
    let stream = TcpStream::connect(&remote_host).await?;
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
