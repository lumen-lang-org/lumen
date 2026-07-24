// http.stream takes (url, method, body, headers) — four arguments.
let s = http.stream("http://127.0.0.1:8080/", "GET", "");
console.log(s.status());
