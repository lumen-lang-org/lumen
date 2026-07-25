// A header value is a string, whatever it looks like: `Content-Length: 12` is
// the text "12". A program that wants a number converts it, and one that
// forgets to is told so rather than being handed a coincidence.
function onRequest(req: HttpRequest): HttpResponse {
  const length: int = req.headers.get("content-length") ?? 0;
  return { status: 200, body: req.body, ok: length > 0, headers: new Map<string, string>() };
}

http.createServer(18099, onRequest);
