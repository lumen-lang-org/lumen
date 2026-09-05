// `net.*` (specs 054, 490): blocking `Socket.read()` and one thread per
// accepted connection. Both need the I/O broker of spec 508; until it lands
// a program that reaches them fails by name rather than hanging.
export function connect() {
  throw new Error("net.connect needs the I/O broker, spec 508");
}

export function createServer() {
  throw new Error("net.createServer needs the I/O broker, spec 508");
}
