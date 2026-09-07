// net.createServer's SYNC handler form is refused on the node target (spec
// 511: the only accepted form there is `async`) -- unlike net.connect/
// http.request/http.stream/child_process.spawn, which spec 508 T005-T007
// wired to its I/O broker unconditionally.
net.createServer(8080, (socket: Socket) => {
  socket.write(socket.read());
});
