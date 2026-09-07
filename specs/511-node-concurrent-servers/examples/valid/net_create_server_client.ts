// The client half of net_create_server.ts's proof, split into its own
// module deliberately: `Worker.run` re-executes its whole target module's
// top-level code on the spawned thread (spec 508 T009's own documented
// consequence). If `runClient` lived in the SAME file as the
// `net.createServer(...)` call, the worker thread would call
// `net.createServer` a second time and hit `EADDRINUSE` on the
// already-bound port -- found the hard way, running this conformance case
// and watching it hang instead of print anything (the exact bug
// `broker.mjs`'s `opListen` fix, resolving a failed listen instead of
// hanging its promise forever, was needed to even surface as a real error
// instead of a silent timeout).
export function runClient(): bool {
  let socket = net.connect("127.0.0.1", 9911);
  socket.write("hello-511");
  let reply = socket.read();
  socket.close();
  return reply == "hello-511";
}
