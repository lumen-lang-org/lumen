// net.createServer needs a per-connection OS thread whose handler shares
// module state, which Node's isolate-per-thread model cannot give without
// an `async` handler form the language does not have yet -- refused
// permanently on the node target (spec 508's Decision, point 3), unlike
// net.connect/http.request/http.stream/child_process.spawn, which spec
// 508 T005-T007 wired to its I/O broker.
net.createServer(8080, (socket: Socket) => {
  socket.write(socket.read());
});
