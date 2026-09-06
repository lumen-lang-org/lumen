// `process.*` (specs 033, 050, 053, 475) plus the two argument globals
// `argsCount()`/`arg(i)`. Lumen exposes Node's properties as calls
// (`process.platform()`, `pid()`, `stdout()`), `env(k)` returns
// `string | null`, `argv()` is the program's argv with the program itself at
// index 0, and `sleep(ms)` blocks the thread.
//
// This module builds a Lumen-shaped object of its own and installs nothing
// (FR-004). `installProcess` is what `globals.mjs` uses to graft these names
// onto Node's real `process`, which cannot be replaced wholesale.
import nfs from "node:fs";
import nos from "node:os";
import { bytes, text } from "./lang.mjs";
import { ReadableStream, WritableStream } from "./streams.mjs";
import { syncSleep } from "./broker/sync_bridge.mjs";

// The version marker `process.version()` reports natively
// (`LUMEN_VERSION` in src/lumen_runtime_os.zig): Lumen's, not Node's.
const LUMEN_VERSION = "0.3.1";

const P = globalThis.process;
const real = {
  platform: P.platform,
  arch: P.arch,
  pid: P.pid,
  argv: P.argv,
  env: P.env,
  cwd: P.cwd.bind(P),
  chdir: P.chdir.bind(P),
  exit: P.exit.bind(P),
  abort: P.abort.bind(P),
  kill: P.kill.bind(P),
  umask: P.umask.bind(P),
  uptime: P.uptime.bind(P),
  hrtime: P.hrtime.bigint.bind(P.hrtime),
  memoryUsage: P.memoryUsage.bind(P),
  getuid: P.getuid ? P.getuid.bind(P) : null,
  getgid: P.getgid ? P.getgid.bind(P) : null,
  geteuid: P.geteuid ? P.geteuid.bind(P) : null,
  getegid: P.getegid ? P.getegid.bind(P) : null,
};

const PLATFORMS = new Set(["linux", "darwin", "win32", "freebsd", "openbsd"]);
const ARCHES = new Set(["x64", "ia32", "arm64", "arm", "riscv64"]);

let stdin = null;
let stdout = null;
let stderr = null;

function statusField(label) {
  let status;
  try { status = nfs.readFileSync("/proc/self/status", "latin1"); } catch { return 0; }
  for (const line of status.split("\n")) {
    if (!line.startsWith(label)) continue;
    const kb = parseInt(line.slice(label.length).trim().split(/\s+/)[0], 10);
    return Number.isFinite(kb) ? kb * 1024 : 0;
  }
  return 0;
}

/** A signal name with or without its "SIG" prefix; an unknown name becomes
 *  signal 0, a liveness probe, as the native runtime maps it. */
function signalName(name) {
  const stripped = name.startsWith("SIG") ? name.slice(3) : name;
  return Object.hasOwn(nos.constants.signals, "SIG" + stripped) ? "SIG" + stripped : 0;
}

/** The Lumen-shaped `process` namespace. */
export const process = {
  cwd: () => bytes(real.cwd()),
  chdir: (path) => { try { real.chdir(text(path)); } catch {} },
  // Blocks via the spec 508 broker (a worker-hosted timer plus
  // Atomics.wait), the same mechanism every other blocking surface uses,
  // rather than a bespoke Atomics.wait-with-timeout of its own -- see spec
  // 508 spec.md's Decision. The broker re-arms on undershoot (spike found
  // one `setTimeout` call alone can land under the requested duration).
  sleep: (ms) => { if (ms > 0) syncSleep(Number(ms)); },
  exit: (code) => real.exit(Number(code)),
  env: (key) => { const v = real.env[text(key)]; return v === undefined ? null : bytes(v); },
  platform: () => (PLATFORMS.has(real.platform) ? real.platform : "unknown"),
  arch: () => (ARCHES.has(real.arch) ? real.arch : "unknown"),
  pid: () => real.pid,
  argv: () => real.argv.slice(1).map(bytes),
  uptime: () => real.uptime(),
  hrtime: () => Number(real.hrtime()),
  memoryUsage: () => ({ rss: statusField("VmRSS:"), vsize: statusField("VmSize:") }),
  kill: (pid, signal) => {
    try { real.kill(pid, signalName(text(signal))); return true; } catch { return false; }
  },
  umask: () => real.umask(),
  setUmask: (mask) => real.umask(mask),
  getuid: () => (real.getuid ? real.getuid() : 0),
  getgid: () => (real.getgid ? real.getgid() : 0),
  geteuid: () => (real.geteuid ? real.geteuid() : 0),
  getegid: () => (real.getegid ? real.getegid() : 0),
  abort: () => real.abort(),
  version: () => LUMEN_VERSION,
  stdin: () => (stdin ??= new ReadableStream(0, { closeFd: false })),
  stdout: () => (stdout ??= new WritableStream(1, { closeFd: false })),
  stderr: () => (stderr ??= new WritableStream(2, { closeFd: false })),
};

/** `argsCount()`: the length of the program's argv, program name included. */
export function argsCount() {
  return real.argv.length - 1;
}

/** `arg(i)`: argv[i] (argv[0] is the program), "" past the end. */
export function arg(i) {
  const v = real.argv[i + 1];
  return v === undefined ? "" : bytes(v);
}

/** A function that also reads as the value Node's own property held, so
 *  `process.platform === "linux"` keeps working for JavaScript that runs
 *  beside a Lumen program while `process.platform()` is the Lumen call. */
function callableValue(fn, value) {
  fn.valueOf = () => value;
  fn.toString = () => String(value);
  fn[Symbol.toPrimitive] = () => value;
  return fn;
}

/** A function whose properties are those of `target`, so `process.env.HOME`
 *  and `process.stdout.write(...)` stay usable by Node itself and by the
 *  console while `process.env("HOME")` / `process.stdout()` are Lumen's. */
function callableOver(fn, target) {
  return new Proxy(fn, {
    get: (t, key) => {
      if (key === "call" || key === "apply" || key === "bind") return Reflect.get(t, key);
      const v = Reflect.get(target, key);
      return typeof v === "function" ? v.bind(target) : v;
    },
    set: (t, key, value) => Reflect.set(target, key, value),
    has: (t, key) => Reflect.has(target, key),
    deleteProperty: (t, key) => Reflect.deleteProperty(target, key),
    ownKeys: () => Reflect.ownKeys(target),
    getOwnPropertyDescriptor: (t, key) => {
      const d = Reflect.getOwnPropertyDescriptor(target, key);
      return d ? { ...d, configurable: true } : undefined;
    },
  });
}

/** Grafts the Lumen names onto Node's real `process` object. Idempotent. */
export function installProcess(target = globalThis.process) {
  if (target.__lumen_installed) return target;
  const def = (name, value) => Object.defineProperty(target, name, { value, configurable: true, writable: true });
  def("platform", callableValue(process.platform, real.platform));
  def("arch", callableValue(process.arch, real.arch));
  def("pid", callableValue(process.pid, real.pid));
  def("version", callableValue(process.version, P.version));
  def("argv", callableOver(process.argv, real.argv));
  def("env", callableOver(process.env, real.env));
  def("stdin", callableOver(process.stdin, P.stdin));
  def("stdout", callableOver(process.stdout, P.stdout));
  def("stderr", callableOver(process.stderr, P.stderr));
  for (const name of ["cwd", "chdir", "sleep", "exit", "uptime", "hrtime", "memoryUsage", "kill", "umask", "setUmask", "getuid", "getgid", "geteuid", "getegid", "abort"]) {
    def(name, process[name]);
  }
  def("__lumen_installed", true);
  return target;
}
