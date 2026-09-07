// The client half of http_create_server.ts's proof, split into its own
// module for the same reason net_create_server_client.ts's is: `Worker.run`
// re-executes its whole target module's top-level code on the spawned
// thread, so a client sharing the server's own file would call
// `http.createServer` a second time and hit `EADDRINUSE` on the
// already-bound port.
export function runHttpClient(): bool {
  let resp = http.get("http://127.0.0.1:9912/ping-511");
  return resp.status == 200 && resp.body == "/ping-511";
}
