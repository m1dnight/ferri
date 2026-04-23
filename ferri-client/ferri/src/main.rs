mod protocol;

use std::env;
use std::future::poll_fn;

use futures::AsyncReadExt;
use futures::AsyncWriteExt;
use futures::FutureExt;
use futures::select;
use tokio::net::TcpStream;
use tokio_util::compat::TokioAsyncReadCompatExt;
use yamux::{Config, Connection, Mode};

use protocol::{ClientMessage, ServerMessage};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port: u16 = env::args()
        .nth(1)
        .expect("usage: ferri <port>")
        .parse()
        .expect("port must be a number");

    let stream = TcpStream::connect("localhost:59595").await?;
    let mut conn = Connection::new(stream.compat(), Config::default(), Mode::Client);

    // Open the control stream (stream 1)
    let mut control = poll_fn(|cx| conn.poll_new_outbound(cx)).await?;

    // Drive the connection in the background. Each inbound stream is a visitor
    // request proxied by the server; hand it to a fresh task so concurrent
    // visitors don't block the driver or each other.
    tokio::spawn(async move {
        loop {
            match poll_fn(|cx| conn.poll_next_inbound(cx)).await {
                Some(Ok(stream)) => {
                    tokio::spawn(proxy_stream(stream, port));
                }
                Some(Err(e)) => {
                    eprintln!("yamux error: {e}");
                    break;
                }
                None => break,
            }
        }
    });

    // Send REGISTER
    let frame = protocol::encode(&ClientMessage::Register);
    control.write_all(&frame).await?;

    // Read REGISTERED / ERROR response
    let mut buf = vec![0u8; 1024];
    let n = control.read(&mut buf).await?;
    let (response, _) =
        protocol::decode(&buf[..n]).expect("incomplete or missing response from server");

    match response {
        ServerMessage::Registered { subdomain, .. } => {
            let url = if cfg!(debug_assertions) {
                format!("http://{subdomain}.localhost:8080")
            } else {
                format!("https://{subdomain}.ferri.dev")
            };
            println!("Tunnel live at {url} -> localhost:{port}");
        }
        ServerMessage::Error { reason } => {
            eprintln!("Registration failed: {reason}");
            std::process::exit(1);
        }
    }

    // Keep the connection alive
    futures::future::pending::<()>().await;

    Ok(())
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
