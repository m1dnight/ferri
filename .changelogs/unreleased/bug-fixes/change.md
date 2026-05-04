- When a client disconnected from the server, the stream was not fully closed,
  only half (FIN). Now a RST frame is sent such that the stream is closed
  entirely and stops receiving.