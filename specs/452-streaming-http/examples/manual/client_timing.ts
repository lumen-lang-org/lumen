// Manual test: R1 timing. Run `python3 sse_server.py 8471` first, then this.
// Each decoded line prints with a monotonic timestamp; streaming is proven if
// the first `data:` line's timestamp is ~1s before the last one (the server
// sends one event per second), instead of all lines sharing one timestamp.
let s = http.stream("http://127.0.0.1:8471/", "GET", "", new Map<string, string>());
console.log("status " + s.status());
console.log("content-type " + s.header("Content-Type"));
while (!s.done()) {
  let line = s.readLine();
  if (s.done()) {
    break;
  }
  console.log("t=" + time.monotonic() + " line=[" + line + "]");
}
console.log("t=" + time.monotonic() + " done");
