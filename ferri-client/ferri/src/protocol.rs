//! Control protocol message types and length-prefixed framing.
//!
//! Messages on the control stream (stream 1) are encoded as length-prefixed
//! JSON: a 4-byte big-endian length followed by that many bytes of JSON.
//!
//! ```text
//! ┌──────────┬──────────────────────┐
//! │ len (4B) │ JSON payload (len B) │
//! └──────────┴──────────────────────┘
//! ```

use serde::{Deserialize, Serialize};

/// A message sent from the client to the server on the control stream.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ClientMessage {
    /// Request a tunnel. The server will respond with [`ServerMessage::Registered`]
    /// or [`ServerMessage::Error`].
    Register,
}

/// A message received from the server on the control stream.
#[derive(Debug, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ServerMessage {
    /// The tunnel is live and ready to accept visitor connections.
    Registered { subdomain: String, url: String },
    /// Registration (or another control operation) failed.
    Error { reason: String },
}

/// Encode a [`ClientMessage`] as a length-prefixed JSON frame.
pub fn encode(msg: &ClientMessage) -> Vec<u8> {
    let json = serde_json::to_vec(msg).expect("failed to serialize message");
    let len = (json.len() as u32).to_be_bytes();
    [&len[..], &json].concat()
}

/// Decode a [`ServerMessage`] from a length-prefixed JSON frame.
///
/// Returns the parsed message and the total number of bytes consumed
/// (4-byte header + JSON body), so the caller can advance past the frame
/// in a larger buffer.
///
/// Returns `None` if the buffer does not yet contain a complete frame.
pub fn decode(buf: &[u8]) -> Option<(ServerMessage, usize)> {
    if buf.len() < 4 {
        return None;
    }

    let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;

    if buf.len() < 4 + len {
        return None;
    }

    let msg: ServerMessage =
        serde_json::from_slice(&buf[4..4 + len]).expect("invalid JSON from server");
    Some((msg, 4 + len))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_register() {
        let frame = encode(&ClientMessage::Register);

        // First 4 bytes are the big-endian length of the JSON payload
        let len = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        let json: serde_json::Value = serde_json::from_slice(&frame[4..4 + len]).unwrap();

        assert_eq!(json["type"], "register");
        assert_eq!(frame.len(), 4 + len);
    }

    #[test]
    fn decode_registered() {
        let json = br#"{"type":"registered","subdomain":"abc","url":"https://abc.ferri.dev"}"#;
        let len = (json.len() as u32).to_be_bytes();
        let frame = [&len[..], &json[..]].concat();

        let (msg, consumed) = decode(&frame).unwrap();

        assert_eq!(consumed, frame.len());
        assert_eq!(
            msg,
            ServerMessage::Registered {
                subdomain: "abc".into(),
                url: "https://abc.ferri.dev".into(),
            }
        );
    }

    #[test]
    fn decode_error() {
        let json = br#"{"type":"error","reason":"subdomain_taken"}"#;
        let len = (json.len() as u32).to_be_bytes();
        let frame = [&len[..], &json[..]].concat();

        let (msg, consumed) = decode(&frame).unwrap();

        assert_eq!(consumed, frame.len());
        assert_eq!(
            msg,
            ServerMessage::Error {
                reason: "subdomain_taken".into(),
            }
        );
    }

    #[test]
    fn decode_incomplete_header() {
        assert!(decode(&[0, 0]).is_none());
    }

    #[test]
    fn decode_incomplete_body() {
        // Header says 100 bytes, but only 2 bytes of body present
        let frame = [&100u32.to_be_bytes()[..], &[0, 0]].concat();
        assert!(decode(&frame).is_none());
    }

    #[test]
    fn encode_then_decode_roundtrip() {
        // Encode a Register, manually wrap the response the server would send,
        // then decode it — validates the framing is symmetric.
        let register_frame = encode(&ClientMessage::Register);

        // Verify the register frame is well-formed
        let len = u32::from_be_bytes([
            register_frame[0],
            register_frame[1],
            register_frame[2],
            register_frame[3],
        ]) as usize;
        assert_eq!(register_frame.len(), 4 + len);

        // Simulate a server response using the same framing
        let response_json = serde_json::to_vec(&serde_json::json!({
            "type": "registered",
            "subdomain": "test",
            "url": "https://test.ferri.dev"
        }))
        .unwrap();
        let response_len = (response_json.len() as u32).to_be_bytes();
        let response_frame = [&response_len[..], &response_json].concat();

        let (msg, consumed) = decode(&response_frame).unwrap();
        assert_eq!(consumed, response_frame.len());
        assert_eq!(
            msg,
            ServerMessage::Registered {
                subdomain: "test".into(),
                url: "https://test.ferri.dev".into(),
            }
        );
    }
}
