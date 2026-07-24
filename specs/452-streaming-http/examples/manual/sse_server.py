# Manual test fixture: an SSE server that writes one event per second over
# chunked transfer-encoding, printing a timestamp as each event is SENT so a
# client's per-line arrival timestamps can be compared against send times.
# Usage: python3 sse_server.py [port] [n_events] [interval_seconds]
import socket
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8471
n = int(sys.argv[2]) if len(sys.argv) > 2 else 3
interval = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
print(f"listening on {port}", flush=True)

conn, _ = srv.accept()
conn.recv(65536)  # drain the request; content is irrelevant for the fixture
conn.sendall(
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/event-stream\r\n"
    b"Transfer-Encoding: chunked\r\n"
    b"\r\n"
)
for i in range(n):
    body = f"data: event-{i}\n\n".encode()
    frame = f"{len(body):x}\r\n".encode() + body + b"\r\n"
    conn.sendall(frame)
    print(f"sent event-{i} at {time.monotonic():.3f}", flush=True)
    if i < n - 1:
        time.sleep(interval)
conn.sendall(b"0\r\n\r\n")
conn.close()
srv.close()
