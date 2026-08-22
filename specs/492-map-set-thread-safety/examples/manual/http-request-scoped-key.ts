// Not a conformance case: a server never returns, so this one is driven by
// hand. It reproduces lumen#12's original report, and separates the two
// bugs the issue turned out to be (see specs/492-map-set-thread-safety
// /spec.md for the full writeup).
//
// `req.path` is sliced out of `http.createServer`'s per-connection arena
// (freed as soon as the handler returns, deliberately, so a long-running
// server's memory does not grow with every request it has ever served).
// Storing it as a Map key used to store that slice as-is: a dangling
// pointer the moment the connection closes. This needs no concurrency at
// all to crash -- a single client, one connection per request, is enough:
//
//   lumen compile http-request-scoped-key.ts && ./http-request-scoped-key &
//   for i in 1 2 3 4 5 6 7 8; do curl -s http://127.0.0.1:9400/x; echo; done
//
// Before the fix: the first curl gets back `1`; the process segfaults
// inside `eqlBytes` before the second curl's response, and every curl after
// that gets nothing back. After the fix: `1` through `8`, one per line, no
// crash -- swap the loop for a constant string key (see
// specs/492-map-set-thread-safety/spec.md's control test) and the
// unpatched compiler also survives it, which is how the dangling-key
// diagnosis was confirmed rather than assumed.
//
// Separately -- and only once the key is no longer dangling -- concurrent
// clients still race the Map's own bookkeeping if truly overlapping. That
// is bug two, and it is loud now instead of silent or a segfault:
//
//   seq 1 100 | xargs -P 100 -I{} curl -s http://127.0.0.1:9400/x
//
// Before the fix: some responses repeat, some numbers never appear (lost
// updates), occasionally a segfault. After the fix: either every response
// 1..100 appears exactly once, or the process exits with
//
//   http-request-scoped-key.ts:5:7: runtime error: Map or Set used from
//   more than one thread at the same time without synchronization
//
// on its stderr -- an explicit, addressable stop instead of a wrong answer.
let counts = new Map<string, int>();

function handleReq(req: HttpRequest): HttpResponse {
  let key = req.path;
  let prior = counts.get(key) ?? 0;
  counts.set(key, prior + 1);
  let h = new Map<string, string>();
  let resp: HttpResponse = { status: 200, body: `${prior + 1}`, ok: true, headers: h };
  return resp;
}

http.createServer(9400, handleReq);
