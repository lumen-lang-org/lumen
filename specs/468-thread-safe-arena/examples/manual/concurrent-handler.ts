// Not a conformance case: a server never returns, so this one is driven by
// hand. It is the reproduction spec 468 was found with.
//
// The handler does what an ordinary REST handler does -- splits the path,
// builds a couple of maps, concatenates a lot of strings -- and every answer is
// a pure function of the path, so any wrong byte is the runtime's fault and not
// the program's.
//
//   lumen compile concurrent-handler.ts && ./concurrent-handler &
//
// Then hit it from more clients than the box has cores, so several handlers are
// genuinely in flight at once. Twenty-four concurrent clients, fifty requests
// each, is enough:
//
//   seq 1 24 | xargs -P 24 -I{} sh -c \
//     'for i in $(seq 1 50); do curl -s http://127.0.0.1:19411/providers/openai; echo; done' \
//     | sort -u | wc -l
//
// One distinct line is the right answer. Before spec 468 this printed several,
// or the server was gone by the time the loop finished, with
//
//   concurrent-handler.ts:39:3: runtime error: integer overflow
//
// on its stderr -- the shared stack-trace depth counter underflowing, reported
// against a `return` statement that had nothing to do with it.
function handle(req: HttpRequest): HttpResponse {
  const routes = new Map<string, string>();
  routes.set("providers", "P");
  routes.set("models", "M");
  routes.set("keys", "K");

  const parts = req.path.split("/");
  let seg = "";
  let i = 0;
  while (i < parts.length) {
    const p = parts[i];
    if (p.length > 0) {
      seg = seg + "[" + p + "]";
    }
    i = i + 1;
  }

  if (parts.length < 3) {
    return { status: 404, body: "not-found", ok: false, headers: new Map<string, string>() };
  }
  const head = parts[1];
  const tail = parts[2];
  const tag = routes.get(head);
  if (tag == null) {
    return { status: 404, body: "not-found", ok: false, headers: new Map<string, string>() };
  }

  let acc = "";
  let j = 0;
  while (j < 600) {
    acc = acc + tag + "-" + tail + ";";
    j = j + 1;
  }

  const body = "ok:" + head + ":" + tail + ":" + seg + ":" + acc;
  const h = new Map<string, string>();
  h.set("content-type", "text/plain");
  return { status: 200, body: body, ok: true, headers: h };
}

http.createServer(19411, handle);
