use std::future::poll_fn;

use futures::AsyncReadExt;
use futures::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio_util::compat::TokioAsyncReadCompatExt;
use yamux::{Config, Connection, Mode};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stream = TcpStream::connect("localhost:59595").await?;
    let mut conn = Connection::new(stream.compat(), Config::default(), Mode::Client);

    // Open an outbound stream
    let mut stream = poll_fn(|cx| conn.poll_new_outbound(cx)).await?;

    // Drive the connection in the background — needs a separate task since
    // conn is borrowed mutably by poll_new_outbound above, so we move it after.
    tokio::spawn(async move {
        loop {
            match poll_fn(|cx| conn.poll_next_inbound(cx)).await {
                Some(Ok(_stream)) => {}
                Some(Err(e)) => {
                    eprintln!("yamux error: {e}");
                    break;
                }
                None => break,
            }
        }
    });

    // Send "hello world"
    stream.write_all(b"hello world").await?;
    println!("sent: hello world");

    // Read the reply
    let mut buf = vec![0u8; 1024];
    let n = stream.read(&mut buf).await?;
    println!("received: {}", String::from_utf8_lossy(&buf[..n]));

    stream.close().await?;
    Ok(())
}
