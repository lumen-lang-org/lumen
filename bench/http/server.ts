// Lumen HTTP server: fixed plaintext response, mirrors the Node server.
function handle(req: HttpRequest): HttpResponse {
  return { status: 200, body: "Hello, World!", ok: true, headers: new Map<string, string>() };
}
http.createServer(8081, handle);
