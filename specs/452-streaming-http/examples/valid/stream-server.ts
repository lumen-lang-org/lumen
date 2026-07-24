// Compile-only: the two-parameter streaming handler form of
// http.createServer, with an explicit head, incremental writes, and an end.
http.createServer(8080, (req: HttpRequest, res: ResponseWriter): void => {
  let h = new Map<string, string>();
  h.set("Content-Type", "text/event-stream");
  res.writeHead(200, h);
  res.write("data: " + req.path + "\n\n");
  res.write("data: two\n\n");
  res.end();
});
