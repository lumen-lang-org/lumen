// Manual test: the AI-service edge shape — a streaming handler that opens an
// upstream stream (run `python3 sse_server.py 8471` first) and forwards it
// line by line. Verify with `curl -N http://127.0.0.1:8474/`: each upstream
// event must appear as it is generated, not after the upstream finishes.
http.createServer(8474, (req: HttpRequest, res: ResponseWriter): void => {
  let up = http.stream("http://127.0.0.1:8471/", "GET", "", new Map<string, string>());
  let h = new Map<string, string>();
  h.set("Content-Type", "text/event-stream");
  res.writeHead(200, h);
  if (up.status() != 200) {
    res.write("data: upstream error\n\n");
    res.end();
    return;
  }
  while (!up.done()) {
    let line = up.readLine();
    if (up.done()) {
      break;
    }
    res.write(line + "\n");
  }
  up.close();
  res.end();
});
