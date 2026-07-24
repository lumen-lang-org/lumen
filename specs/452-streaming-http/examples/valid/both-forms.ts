// Compile-only: the buffered one-parameter form and the streaming
// two-parameter form coexist in one program (on different ports).
function buffered(req: HttpRequest): HttpResponse {
  return { status: 200, body: "hello", ok: true, headers: new Map<string, string>() };
}

function streaming(req: HttpRequest, res: ResponseWriter): void {
  res.write("data: hi\n\n");
  res.end();
}

let mode = 1;
if (mode == 1) {
  http.createServer(8080, buffered);
} else {
  http.createServer(8081, streaming);
}
