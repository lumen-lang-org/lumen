// An HTTP peer for http.mjs tests, run as its own OS process for the same
// reason tests/fixtures/broker_peer.mjs is: the broker's Atomics.wait
// blocks this process's main thread for the whole request, so a
// same-process server could never get its own 'connection'/'request'
// event loop turn to answer it (see spec 508 spec.md, "Why the dump server
// is a separate OS process"). Listens on an ephemeral port, prints
// "PORT <n>" once ready.
//
//   GET|POST /echo   -> 200, body is "<method> <path> <headers.x-tag> <body>"
//   GET      /lines  -> 200, three chunks flushed one at a time (for
//                       http.stream's readLine()), 40ms apart so a naive
//                       reader that only looked at the first chunk would
//                       see a truncated body
//   GET      /status/<n> -> that status code, empty body
import http from "node:http";

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("latin1");
    if (req.url === "/echo") {
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(`${req.method} ${req.url} ${req.headers["x-tag"] ?? ""} ${body}`);
      return;
    }
    if (req.url === "/lines") {
      res.writeHead(200, { "content-type": "text/event-stream" });
      let i = 0;
      const tick = () => {
        i += 1;
        res.write(`data: ${i}\n`);
        if (i < 3) setTimeout(tick, 40);
        else res.end();
      };
      tick();
      return;
    }
    const m = /^\/status\/(\d+)$/.exec(req.url);
    if (m) {
      res.writeHead(Number(m[1]));
      res.end();
      return;
    }
    res.writeHead(404);
    res.end();
  });
});
server.listen(0, "127.0.0.1", () => {
  console.log("PORT " + server.address().port);
});
