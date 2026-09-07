// http.createServer's buffered async handler form (spec 511 T012): the
// same shape net_create_server.ts proves for net.createServer, but for
// http -- a real listener, a real client request over loopback, a real
// response.
//
// The handler MUST be a named `async function`, not an inline arrow, for
// the same reason net_create_server.ts's is: arrows are not `async` in
// this language subset at all (a deliberate V1 restriction, not a bug).
//
// `runHttpClient` lives in its own module (`http_create_server_client.ts`),
// not this one, for the same reason net_create_server.ts's client does:
// `Worker.run` re-executes its whole target module's top level on the
// spawned thread, which would call `http.createServer` a second time (and
// hit `EADDRINUSE`) if the client and the server shared a file.
import { runHttpClient } from "./http_create_server_client.ts";

async function handleRequest(req: HttpRequest): Promise<HttpResponse> {
  let headers: Map<string, string> = new Map<string, string>();
  return { status: 200, body: req.path, ok: true, headers: headers };
}
http.createServer(9912, handleRequest);

async function main(): Promise<void> {
  let ok = await Worker.run(runHttpClient);
  console.log(ok ? "ok" : "fail");
  process.exit(0);
}
main();
