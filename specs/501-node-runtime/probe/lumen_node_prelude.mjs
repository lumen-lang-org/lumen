// Prototype: Lumen's global namespaces on top of Node's built-ins (measurement only).
import nfs from "node:fs"; import npath from "node:path"; import nos from "node:os"; import ncrypto from "node:crypto"; import ncp from "node:child_process";
const g = globalThis;
const utf8 = (r) => (Buffer.isBuffer(r) ? r.toString("utf8") : r);
g.fs = { ...nfs,
  readFileSync: (p, enc) => nfs.readFileSync(p, enc ?? "utf8"),
  readSync: (fd, n) => { const b = Buffer.alloc(n); const k = nfs.readSync(fd, b, 0, n, null); return b.subarray(0, k).toString("latin1"); },
  writeSync: (fd, s) => nfs.writeSync(fd, s),
  statSync: (p) => { const s = nfs.statSync(p); return { size: s.size, mtimeMs: s.mtimeMs, isFile: s.isFile(), isDirectory: s.isDirectory() }; },
};
g.path = npath; g.os = { ...nos, platform: () => nos.platform(), arch: () => nos.arch(), homedir: () => nos.homedir(), tmpdir: () => nos.tmpdir(), EOL: () => nos.EOL };
g.time = { now: () => Date.now(), monotonic: () => Math.floor(performance.now()) };
Object.defineProperty(g, "crypto", { configurable: true, value: { ...ncrypto,
  randomBytes: (n) => ncrypto.randomBytes(n).toString("hex"), randomUUID: () => ncrypto.randomUUID(),
  sha256: (s) => ncrypto.createHash("sha256").update(s, "latin1").digest("hex"),
  sha1: (s) => ncrypto.createHash("sha1").update(s, "latin1").digest("hex"),
  sha1Bytes: (s) => ncrypto.createHash("sha1").update(s, "latin1").digest("latin1"),
  base64Encode: (s) => Buffer.from(s, "latin1").toString("base64"), base64Decode: (s) => Buffer.from(s, "base64").toString("latin1"),
  timingSafeEqual: (a, b) => a.length === b.length && ncrypto.timingSafeEqual(a, b),
} });
g.child_process = { spawnSync: (cmd, args) => { const r = ncp.spawnSync(cmd, args, { encoding: "utf8" }); return { stdout: r.stdout ?? "", stderr: r.stderr ?? "", status: r.status ?? -1 }; } };
g.argsCount = () => process.argv.length - 1; g.arg = (i) => process.argv[i + 1] ?? "";
const P = process; const plat = P.platform, arch = P.arch, out = P.stdout, err = P.stderr, inp = P.stdin;
Object.defineProperty(P, "platform", { value: () => plat, configurable: true });
Object.defineProperty(P, "arch", { value: () => arch, configurable: true });
const callableStream = (real, fd) => new Proxy(function () {}, { apply: () => ({ write: (s) => nfs.writeSync(fd, s), close() {} }), get: (t, k) => { const v = real[k]; return typeof v === "function" ? v.bind(real) : v; } });
Object.defineProperty(P, "stdout", { value: callableStream(out, 1), configurable: true });
Object.defineProperty(P, "stderr", { value: callableStream(err, 2), configurable: true });
P.sleep = (ms) => { if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); };
P.cwd = P.cwd.bind(P); { const v = P.pid; Object.defineProperty(P, "pid", { value: () => v, configurable: true }); }
g.Worker = { run: (fn) => Promise.resolve().then(fn) };
g.net = { connect: () => { throw new Error("net.connect: not shimmed"); }, createServer: () => { throw new Error("net.createServer: not shimmed"); } };
g.http = { request: () => { throw new Error("http.request: not shimmed"); }, stream: () => { throw new Error("http.stream: not shimmed"); }, createServer: () => { throw new Error("http.createServer: not shimmed"); } };
g.url = { parse: (s) => { const u = new URL(s); return { protocol: u.protocol, hostname: u.hostname, port: u.port, pathname: u.pathname, search: u.search, hash: u.hash, href: u.href }; } };
g.assert = { ok: (c, m) => { if (!c) throw new Error(m ?? "assert"); }, equal: (a, b, m) => { if (a !== b) throw new Error(m ?? "assert.equal"); } };
g.defer = (fn) => ({ dispose: fn });
// test / expect
g.__t = { pass: 0, fail: 0, failures: [] };
g.test = (name, fn) => { try { const r = fn(); if (r && typeof r.then === "function") r.catch((e) => { g.__t.fail++; g.__t.failures.push(name + ": " + e.message); }); else g.__t.pass++; } catch (e) { g.__t.fail++; g.__t.failures.push(name + ": " + (e && e.message)); } };
g.expect = (c) => { if (c === false) throw new Error("expect(false)"); return { toBe(v) { if (c !== v) throw new Error(`expected ${JSON.stringify(v)}, got ${JSON.stringify(c)}`); }, toEqual(v) { if (JSON.stringify(c) !== JSON.stringify(v)) throw new Error("toEqual"); } }; };
