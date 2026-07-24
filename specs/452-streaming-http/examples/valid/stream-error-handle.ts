// A refused connection yields a degraded handle, never a crash:
// status() == -1, done() true, readLine() "", header() "".
let s = http.stream("http://127.0.0.1:1/", "GET", "", new Map<string, string>());
console.log(s.status());
console.log(s.done());
let line = s.readLine();
console.log(line.length);
console.log(s.header("content-type").length);
s.close();
console.log("ok");
