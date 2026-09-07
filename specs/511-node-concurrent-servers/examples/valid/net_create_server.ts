// net.createServer's async handler form (spec 511), the one working
// end-to-end proof this spec adds: a real listener, a real client
// connection over loopback, an echo round trip.
//
// The handler MUST be a named `async function`, not an inline arrow --
// found the hard way, by actually trying to parse `async (socket) => {...}`
// (a real parse error, not a checker refusal): arrows are not `async` in
// this language subset at all (`lumen_check_expr.zig`, "Arrow functions
// are not async in this subset, so `await` inside an arrow body is
// rejected" -- a deliberate V1 restriction, not a bug). This is a real
// Lumen-syntax constraint on Joule's own eventual adoption (spec 004/511
// tasks.md T015), not a compiler limitation this spec's own scope needs to
// lift.
//
// The socket parameter's type is `AsyncSocket`, not `Socket`: a
// genuinely different type (`lumen_check_methods.zig`'s
// `asyncSocketMethod`), not "Socket used inside an async function" -- a
// plain `net.connect()` `Socket` stays sync-backed regardless of its
// caller's own asyncness, on both targets.
//
// `runClient` lives in its own module (`net_create_server_client.ts`), not
// this one -- see that file's own comment for why: `Worker.run`
// re-executes its whole target module's top level on the spawned thread,
// which would call `net.createServer` a second time if the client and the
// server shared a file.
import { runClient } from "./net_create_server_client.ts";

async function handleConn(socket: AsyncSocket): Promise<void> {
  let msg = await socket.read();
  await socket.write(msg);
  await socket.close();
}
net.createServer(9911, handleConn);

async function main(): Promise<void> {
  let ok = await Worker.run(runClient);
  console.log(ok ? "ok" : "fail");
  process.exit(0);
}
main();
