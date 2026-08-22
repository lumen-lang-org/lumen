// Not a conformance case: a server never returns, so this one is driven by
// hand. It reproduces the "New evidence" comment on lumen#12: a shared
// `Store` (a `Map<string, int>` and a plain `int` counter) mutated from
// `net.createServer`'s thread pool (lumen#27 / spec 490).
//
// `net.createServer`'s `Socket.read()` already copies into the runtime's
// persistent arena (see its own comment in
// src/lumen_runtime_net.zig), so unlike the `http.createServer` companion
// example in this same directory, this one is not the dangling-key bug --
// it is bug two on its own: two threads mutating one Map's bookkeeping (and
// one plain `totalOps` field) at once, with nothing serialising them.
//
// Drive it with bash's own TCP support, no extra tools required. Each
// connection sends one tag and reads one line back:
//
//   lumen compile net-store-concurrent-map.ts && ./net-store-concurrent-map &
//
//   one() { exec {fd}<>/dev/tcp/127.0.0.1/8995; echo "$1" >&"$fd"; cat <&"$fd"; exec {fd}<&-; }
//   export -f one
//
// Light load -- ten connections, three thousand ops each -- silently loses
// updates before the fix (an `own=` short of 3000, a `total=` short of
// 30000) and prints nothing to stderr either way:
//
//   seq 0 9 | xargs -P 10 -I{} bash -c 'one conn{}'
//
// Heavy load -- twenty connections, same op count -- crashes the process
// before the fix, interleaved output from several threads hitting the same
// panic at once:
//
//   seq 0 19 | xargs -P 20 -I{} bash -c 'one conn{}'
//
//   net-store-concurrent-map.ts:12:9: runtime error: index out of bounds: index 12, len 12
//
// After the fix, light load either completes with every `own=3000` and
// `total=30000`, or stops immediately with
//
//   net-store-concurrent-map.ts:12:9: runtime error: Map or Set used from
//   more than one thread at the same time without synchronization
//
// -- an explicit, addressable stop instead of either silently wrong numbers
// or a segfault reported from deep inside string-equality code that has
// nothing to do with the actual bug. The plain `totalOps` counter can still
// lose updates even after this fix: it is not a Map, so the guard does not
// see it, and that is exactly the "the program's own bug" boundary this
// spec documents rather than closes -- see the "Not fixed here" section of
// specs/492-map-set-thread-safety/spec.md.
const PORT: int = 8995;
const OPS_PER_CONN: int = 3000;

export class Store {
  counts: Map<string, int>;
  totalOps: int;
  constructor() {
    this.counts = new Map<string, int>();
    this.totalOps = 0;
  }
  bump(key: string): void {
    let cur = this.counts.get(key) ?? 0;
    this.counts.set(key, cur + 1);
    this.totalOps = this.totalOps + 1;
  }
}

let store = new Store();

function handleConnection(socket: Socket, onMessage: (tag: string) => string): void {
  let buf = "";
  while (buf.indexOf("\n") < 0) {
    let chunk = socket.read();
    if (chunk == "") { socket.close(); return; }
    buf = buf + chunk;
  }
  let tag = buf.trim();
  let result = onMessage(tag);
  socket.write(result + "\n");
  socket.close();
}

function makeOnMessage(s: Store): (tag: string) => string {
  return (tag: string) => {
    let i = 0;
    while (i < OPS_PER_CONN) { s.bump(tag); i = i + 1; }
    return "done " + tag + " total=" + `${s.totalOps}` + " own=" + `${s.counts.get(tag) ?? -1}`;
  };
}

let onMessage = makeOnMessage(store);

net.createServer(PORT, (socket: Socket) => {
  handleConnection(socket, onMessage);
});
