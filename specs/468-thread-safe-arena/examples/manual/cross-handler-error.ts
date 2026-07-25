// Not a conformance case: a server never returns. The second reproduction --
// the one that shows the wrong answer rather than the crash.
//
// Every request throws an error naming its own path and catches it one frame
// up, so the answer always repeats the path that asked for it. Nothing is
// shared between requests.
//
//   lumen compile cross-handler-error.ts && ./cross-handler-error &
//   seq 1 24 | xargs -P 24 -I{} sh -c \
//     'for i in $(seq 1 40); do curl -s http://127.0.0.1:19412/foxtrot; echo; done' \
//     | sort -u
//
// Before spec 468 that occasionally printed a line naming a path nobody in this
// loop asked for:
//
//   caught=no-such-thing:delta
//
// -- one handler's `throw` read out of the shared message slot by another
// handler's `catch`. A router that turns a caught error into a 404 answers a
// perfectly good URL with someone else's not-found, then answers it correctly
// on the next try.
function lookup(name: string): string {
  if (name.length > 0) {
    throw new Error("no-such-thing:" + name);
  }
  return "unreachable";
}

function handle(req: HttpRequest): HttpResponse {
  const parts = req.path.split("/");
  if (parts.length < 2) {
    return { status: 400, body: "bad", ok: false, headers: new Map<string, string>() };
  }
  const name = parts[1];
  let caught = "none";
  try {
    const v = lookup(name);
    caught = "no-throw:" + v;
  } catch (e) {
    caught = e.message;
  }
  return { status: 200, body: "caught=" + caught, ok: true, headers: new Map<string, string>() };
}

http.createServer(19412, handle);
