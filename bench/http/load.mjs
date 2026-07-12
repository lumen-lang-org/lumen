// Minimal autocannon-style load client: C keep-alive connections, fire
// pipelined-serial requests for DURATION seconds, count completed responses.
import http from "node:http";
const PORT = Number(process.argv[2] || 8082);
const CONNS = Number(process.argv[3] || 50);
const DURATION = Number(process.argv[4] || 5) * 1000;
const agent = new http.Agent({ keepAlive: true, maxSockets: CONNS });
let done = 0, inflight = 0, stop = false;
const start = Date.now();
function fire() {
  if (stop) return;
  inflight++;
  const req = http.get({ host: "127.0.0.1", port: PORT, path: "/", agent }, (res) => {
    res.on("data", () => {});
    res.on("end", () => { done++; inflight--; if (!stop) fire(); });
  });
  req.on("error", () => { inflight--; if (!stop) setTimeout(fire, 1); });
}
for (let i = 0; i < CONNS; i++) fire();
setTimeout(() => {
  stop = true;
  const secs = (Date.now() - start) / 1000;
  console.log(`${(done / secs).toFixed(0)} req/sec (${done} in ${secs.toFixed(1)}s, ${CONNS} conns)`);
  process.exit(0);
}, DURATION);
