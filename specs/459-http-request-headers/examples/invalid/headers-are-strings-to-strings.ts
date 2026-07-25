// The request's headers are a `Map<string,string>` -- the response's type
// exactly -- so a program that expects any other value type is told which one
// it really has instead of finding out at run time.
function onRequest(req: HttpRequest): HttpResponse {
  const counts: Map<string, int> = req.headers;
  return { status: 200, body: req.path, ok: counts.has("x"), headers: new Map<string, string>() };
}

http.createServer(18099, onRequest);
