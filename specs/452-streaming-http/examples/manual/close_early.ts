// Manual test: early close mid-stream. Run `python3 sse_server.py 8471 3 1`
// first. After close(), readLine() returns "" and done() flips true — and the
// fixture's connection drops (its remaining sends fail or are discarded).
let s = http.stream("http://127.0.0.1:8471/", "GET", "", new Map<string, string>());
console.log("status " + s.status());
let first = s.readLine();
console.log("first=[" + first + "]");
s.close();
let after = s.readLine();
console.log("after-close=[" + after + "] done=" + s.done());
