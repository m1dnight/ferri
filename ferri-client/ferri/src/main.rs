mod protocol;

use std::env;
use std::future::poll_fn;

use anyhow::Context;
use futures::AsyncReadExt;
use futures::AsyncWriteExt;
use futures::FutureExt;
use futures::select;
use tokio::net::TcpStream;
use tokio_util::compat::TokioAsyncReadCompatExt;
use yamux::Stream;
use yamux::{Config, Connection, Mode};

use protocol::{ClientMessage, ServerMessage};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse the port to connect to locally.
    let port: u16 = env::args()
        .nth(1)
        .expect("usage: ferri <port>")
        .parse()
        .expect("port must be a number");

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
    let url = format_url(subdomain);
    println!("Tunnel live at {url} -> localhost:{port}");

    // Keep the connection alive
    futures::future::pending::<()>().await;

    Ok(())
}

/// Formats the session name into the full URL.
/// In debugging this is localhost, otherwise ferri.
fn format_url(subdomain: String) -> String {
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
async fn proxy_stream(stream: yamux::Stream, port: u16) {
    let tcp = match TcpStream::connect(("127.0.0.1", port)).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to dial localhost:{port}: {e}");
            return;
        }
    };

    let (mut tcp_in, mut tcp_out) = tcp.compat().split();
    let (mut yamux_in, mut yamux_out) = stream.split();

    let to_local = async {
        let n = futures::io::copy(&mut yamux_in, &mut tcp_out).await;
        eprintln!("Connection to Ferri stream terminated: {n:?}");
        let _ = tcp_out.close().await;
        eprintln!("yamux -> local ended: {n:?}");
        n
    };
    let to_remote = async {
        let n = futures::io::copy(&mut tcp_in, &mut yamux_out).await;
        eprintln!("Connection to local endpoint terminated: {n:?}");
        let _ = yamux_out.close().await;
        n
    };

    select! {
        _ = to_remote.fuse() => {
            // Ferri server closed the connection
            let _ = tcp_out.close().await;
            println!("to_remote finished");
        },
        _ = to_local.fuse() => {
            // The local connection disconnected, so we won't be writing to yamux anymore.
            let _ = yamux_out.close().await;
            println!("to_local finished");
        }
    }
}
