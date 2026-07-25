// The request's headers are an ordinary Map<string,string> -- the same type the
// response carries -- so every Map method applies to them.
function onRequest(req: HttpRequest): HttpResponse {
  const count: string = `${req.headers.size}`;
  let out = "anonymous";
  if (req.headers.has("authorization")) {
    out = "authenticated";
  }
  out = out + " " + count;
  const names = req.headers.keys();
  let i: int = 0;
  while (i < names.length) {
    out = out + " " + names[i];
    i = i + 1;
  }
  const echo = new Map<string, string>();
  echo.set("x-request-path", req.path);
  return { status: 200, body: out, ok: true, headers: echo };
}

http.createServer(18099, onRequest);
