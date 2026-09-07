// net.createServer's SYNC handler form is refused on the node target (spec
// 511): the only accepted form there is `async`, real support since 511 --
// this pins that boundary, not a blanket "createServer is refused" claim
// anymore (see examples/valid/net_create_server.ts for the working form).
net.createServer(8080, (socket: Socket) => {
  socket.write(socket.read());
});
