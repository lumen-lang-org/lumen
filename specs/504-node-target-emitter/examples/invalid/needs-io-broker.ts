// The blocking network calls need spec 508's I/O broker: the runtime package
// only stubs them, and a stub throwing at run time is not the diagnostic
// FR-005 promises.
function fetchLine(): string {
  const socket = net.connect("localhost", 8080);
  socket.write("hello\n");
  return socket.read();
}
console.log(fetchLine());
