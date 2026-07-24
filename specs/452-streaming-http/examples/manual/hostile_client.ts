// Manual test: hostile chunked body. Run `python3 hostile_server.py 8472`
// first, then this. The decoded lines must be exactly the logical body lines
// ("1a", "not a chunk header", "ff", "plain line", "0", "tail") — chunk
// framing must never leak through, even when the data itself looks like it.
let s = http.stream("http://127.0.0.1:8472/", "GET", "", new Map<string, string>());
console.log("status " + s.status());
while (!s.done()) {
  let line = s.readLine();
  if (s.done()) {
    break;
  }
  console.log("[" + line + "]");
}
console.log("end");
