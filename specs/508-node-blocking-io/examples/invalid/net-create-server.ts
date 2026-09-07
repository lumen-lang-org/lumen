// SC-003: net.createServer is refused on the node target, permanently --
// not just until wired up (spec 508's Decision, point 3: no per-connection
// handler model that shares module state without giving up concurrency).
net.createServer(8080, (socket: Socket) => {
  socket.write(socket.read());
});
