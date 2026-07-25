// Not a conformance case: a server never returns, so this one is driven by
// hand. It echoes back what it read from the request's headers, which is how
// the parsing rules below were checked against a real client.
//
//   lumen compile header-echo.ts && ./header-echo &
//   curl -s -H "Authorization: Bearer abc" -H "X-Thing: 1" http://127.0.0.1:18099/probe
//   -> auth=Bearer abc|x-thing=1|content-type=missing|exact-case=missing|dup=missing|empty=missing
//
// `Authorization` is found as `authorization` (names are lowercased), while
// `X-Thing` is not found under the case the client sent it in -- the lowercase
// name is the only key. A raw request exercises the rest:
//
//   printf 'GET /raw HTTP/1.1\r\nHost: h\r\nX-Dup: first\r\nX-Empty:\r\ngarbage-no-colon\r\nX-Dup: second\r\nConnection: close\r\n\r\n' | nc 127.0.0.1 18099
//   -> ...|dup=second|empty=missing
//
// -- the last of a repeated header wins, a header with no value is dropped,
// and a line that is not a header at all does not stop the server answering.
function onRequest(req: HttpRequest): HttpResponse {
  const auth = req.headers.get("authorization") ?? "missing";
  const thing = req.headers.get("x-thing") ?? "missing";
  const ctype = req.headers.get("content-type") ?? "missing";
  const exact = req.headers.get("X-Thing") ?? "missing";
  const dup = req.headers.get("x-dup") ?? "missing";
  const empty = req.headers.get("x-empty") ?? "missing";
  const out = "auth=" + auth + "|x-thing=" + thing + "|content-type=" + ctype + "|exact-case=" + exact + "|dup=" + dup + "|empty=" + empty;
  return { status: 200, body: out, ok: true, headers: new Map<string, string>() };
}

http.createServer(18099, onRequest);
