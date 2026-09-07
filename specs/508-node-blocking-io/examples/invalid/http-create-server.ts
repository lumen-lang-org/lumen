// http.createServer is still refused on the node target -- spec 511 gave
// net.createServer real async-handler support but did not extend it to
// http.createServer's buffered/streaming handler forms (511 tasks.md T012,
// a documented follow-up, not implemented in that pass).
function onRequest(req: HttpRequest): HttpResponse {
  return { status: 200, body: "", ok: true, headers: new Map<string, string>() };
}
http.createServer(8080, onRequest);
