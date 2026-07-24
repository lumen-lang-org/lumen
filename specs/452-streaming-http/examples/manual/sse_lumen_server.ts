// Manual test: R2 timing + keep-alive. Run this, then in another terminal:
//   curl -N http://127.0.0.1:8473/        (each event appears ~1s apart)
//   curl -N http://127.0.0.1:8473/a http://127.0.0.1:8473/b
//     (two requests on one connection — keep-alive after a streamed response)
function pause(ms: i64): void {
  // No sleep primitive yet; a busy-wait is fine for a manual fixture.
  let start = time.monotonic();
  while (time.monotonic() - start < ms) {
  }
}

http.createServer(8473, (req: HttpRequest, res: ResponseWriter): void => {
  let h = new Map<string, string>();
  h.set("Content-Type", "text/event-stream");
  res.writeHead(200, h);
  res.write("data: one " + req.path + "\n\n");
  pause(1000);
  res.write("data: two " + req.path + "\n\n");
  pause(1000);
  res.write("data: three " + req.path + "\n\n");
  res.end();
});
