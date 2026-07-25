// The streaming two-parameter handler reads request headers exactly as the
// buffered one does: it is the same request record, so content negotiation is
// possible in the form that streams.
function onRequest(req: HttpRequest, res: ResponseWriter): void {
  const accept = req.headers.get("accept") ?? "*/*";
  const headers = new Map<string, string>();
  headers.set("content-type", "text/event-stream");
  res.writeHead(200, headers);
  res.write("data: " + accept + "\n\n");
  res.end();
}

http.createServer(18099, onRequest);
