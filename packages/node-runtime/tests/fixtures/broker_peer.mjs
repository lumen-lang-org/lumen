// A one-shot TCP peer for broker tests, run as its own OS process so it can
// never be affected by the caller's own `Atomics.wait` -- a same-process
// peer deadlocks the calling thread's wait against the very event loop turn
// its 'connection' handler needs (see spec 508 spec.md, "Why the dump
// server is a separate OS process"). Listens on an ephemeral port, prints
// "PORT <n>" once ready, then handles exactly one connection:
//   argv[2] === "echo": echoes back whatever it receives until the client
//     ends, then ends itself.
//   otherwise: writes the base64-decoded argv[3] and ends, both in the same
//     synchronous turn -- the fast-peer race spec 508's spike found (data
//     and EOF delivered before a listener attached a tick later would see
//     them).
import net from "node:net";

const mode = process.argv[2];
const payload = process.argv[3] ? Buffer.from(process.argv[3], "base64") : Buffer.alloc(0);

const server = net.createServer((sock) => {
  if (mode === "echo") {
    sock.on("data", (d) => sock.write(d));
    sock.on("end", () => sock.end());
  } else {
    sock.write(payload);
    sock.end();
  }
  sock.on("close", () => server.close());
});
server.listen(0, "127.0.0.1", () => {
  console.log("PORT " + server.address().port);
});
