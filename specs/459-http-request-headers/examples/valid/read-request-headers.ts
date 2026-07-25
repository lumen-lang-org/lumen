// A buffered handler reads the headers it was sent. Names are lowercased, so a
// lookup is written one way whatever case the client chose, and a header that
// was not sent reads as null rather than as an empty string.
function onRequest(req: HttpRequest): HttpResponse {
  const auth = req.headers.get("authorization") ?? "anonymous";
  const ctype = req.headers.get("content-type") ?? "application/octet-stream";
  const out = req.method + " " + req.path + " " + auth + " " + ctype;
  return { status: 200, body: out, ok: true, headers: new Map<string, string>() };
}

http.createServer(18099, onRequest);
