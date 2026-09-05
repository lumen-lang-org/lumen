// `os.*` (spec 034). `EOL()`, `devNull()`, `platform()` are calls. The
// integer results are `int`, truncated to 32 bits exactly as the native
// runtime truncates them (`totalmem()` on a machine with more than 2 GiB
// wraps there too).
import nos from "node:os";
import { platform as nodePlatform, arch as nodeArch, env as nodeEnv } from "node:process";
import { bytes } from "./lang.mjs";

const PLATFORMS = new Set(["linux", "darwin", "win32", "freebsd", "openbsd"]);
const ARCHES = new Set(["x64", "ia32", "arm64", "arm", "riscv64"]);

export function platform() {
  return PLATFORMS.has(nodePlatform) ? nodePlatform : "unknown";
}

export function arch() {
  return ARCHES.has(nodeArch) ? nodeArch : "unknown";
}

export function type() {
  return bytes(nos.type());
}

export function release() {
  return bytes(nos.release());
}

export function version() {
  return bytes(nos.version());
}

export function machine() {
  return bytes(nos.machine());
}

export function hostname() {
  return bytes(nos.hostname());
}

export function endianness() {
  return nos.endianness();
}

/** `tmpdir()`: TMPDIR, TMP, TEMP, then "/tmp" — the native lookup order. */
export function tmpdir() {
  const env = nodeEnv;
  for (const k of ["TMPDIR", "TMP", "TEMP"]) {
    const v = env[k];
    if (v !== undefined) return bytes(v);
  }
  return "/tmp";
}

/** `homedir()`: `$HOME`, "" when unset (the native reading). */
export function homedir() {
  const v = nodeEnv.HOME;
  return v === undefined ? "" : bytes(v);
}

export function EOL() {
  return "\n";
}

export function devNull() {
  return "/dev/null";
}

export function uptime() {
  return Math.trunc(nos.uptime()) | 0;
}

export function totalmem() {
  return Number(nos.totalmem()) | 0;
}

export function freemem() {
  return Number(nos.freemem()) | 0;
}

export function availableParallelism() {
  return nos.availableParallelism();
}

export function loadavg() {
  return nos.loadavg();
}
