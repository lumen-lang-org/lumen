// Compile-only: the full HttpStream client surface, including HttpStream as
// an explicit parameter annotation.
function consume(s: HttpStream): int {
  let n = 0;
  while (!s.done()) {
    let line = s.readLine();
    if (line.length > 0) {
      n = n + 1;
    }
  }
  s.close();
  return n;
}

let headers = new Map<string, string>();
headers.set("Accept", "text/event-stream");
headers.set("Content-Type", "application/json");
let s = http.stream("https://example.com/v1/stream", "POST", "{\"stream\":true}", headers);
console.log(s.status());
console.log(s.header("Content-Type"));
console.log(consume(s));
