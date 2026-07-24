// HttpStream has status/header/readLine/done/close — nothing else.
let s = http.stream("http://127.0.0.1:8080/", "GET", "", new Map<string, string>());
s.frobnicate();
