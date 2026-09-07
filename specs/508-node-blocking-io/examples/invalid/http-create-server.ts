// http.createServer is refused on the node target, permanently -- same
// reason as net.createServer above (spec 508's Decision, point 3).
function onRequest(req: HttpRequest): HttpResponse {
  return { status: 200, body: "", ok: true, headers: new Map<string, string>() };
}
http.createServer(8080, onRequest);
