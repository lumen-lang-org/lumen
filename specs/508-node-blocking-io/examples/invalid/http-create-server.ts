// A SYNC http.createServer handler is refused on the node target (spec
// 511 T012, mirroring net.createServer's own sync/async split): native
// keeps its sync, thread-pooled handler; node needs a named `async
// function` in one of the two accepted async shapes instead.
function onRequest(req: HttpRequest): HttpResponse {
  return { status: 200, body: "", ok: true, headers: new Map<string, string>() };
}
http.createServer(8080, onRequest);
