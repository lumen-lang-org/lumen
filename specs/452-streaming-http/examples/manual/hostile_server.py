# Manual test fixture: a chunked response whose chunk DATA contains \r\n
# pairs and hex-digit-like lines, with chunk boundaries deliberately placed
# mid-line — a naive decoder that scans for \r\n or hex frames inside the
# body corrupts this; a real transfer-decoder round-trips it intact.
# Usage: python3 hostile_server.py [port]
import socket
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8472

# The logical body the client must reconstruct, line for line.
# "1a" and "ff" alone on a line look exactly like chunk-size frames.
body = b"1a\r\nnot a chunk header\r\nff\r\nplain line\r\n0\r\ntail\r\n"

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
print(f"listening on {port}", flush=True)

conn, _ = srv.accept()
conn.recv(65536)
conn.sendall(
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/plain\r\n"
    b"Transfer-Encoding: chunked\r\n"
    b"\r\n"
)
# Split the body into uneven chunks so \r\n pairs straddle chunk boundaries.
cuts = [5, 9, 20, 27, len(body)]
prev = 0
for cut in cuts:
    data = body[prev:cut]
    prev = cut
    conn.sendall(f"{len(data):x}\r\n".encode() + data + b"\r\n")
conn.sendall(b"0\r\n\r\n")
conn.close()
srv.close()
