// http.createServer's async handler form is node-only (spec 511 T012,
// decision 1): native stays sync-only, refused here with a real
// diagnostic at check time (lumen_check_stdlib.zig's
// httpServerHandlerIsAsync) rather than failing two stages downstream at
// `zig build-exe`.
async function handleRequest(req: HttpRequest): Promise<HttpResponse> {
  return { status: 200, body: "", ok: true, headers: new Map<string, string>() };
}
http.createServer(9912, handleRequest);
