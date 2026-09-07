// net.createServer's async handler form is node-only (spec 511 decision
// 1): native stays sync-only, refused here with a real diagnostic at
// check time (lumen_check_stdlib.zig's netCallType, T010) rather than
// failing two stages downstream at `zig build-exe` with a raw "undeclared
// identifier" error.
async function handleConn(socket: AsyncSocket): Promise<void> {
  await socket.close();
}
net.createServer(9911, handleConn);
