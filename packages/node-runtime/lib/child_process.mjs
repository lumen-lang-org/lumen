// `child_process.*` (specs 037, 450). `spawnSync(cmd, args)` runs to
// completion with stdin ignored and returns `{ stdout, stderr, status }` as
// strings and an int: -1 when the command could not start or died by a
// signal. `spawn` keeps a process alive with blocking `readLine` (spec 450)
// and needs the I/O broker of spec 508.
import ncp from "node:child_process";
import { text, fromBuffer } from "./lang.mjs";

export function spawnSync(command, args) {
  const r = ncp.spawnSync(text(command), args.map(text), {
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 16 * 1024 * 1024,
  });
  return {
    stdout: r.stdout ? fromBuffer(r.stdout) : "",
    stderr: r.stderr ? fromBuffer(r.stderr) : "",
    status: r.error || r.status === null ? -1 : r.status,
  };
}

export function spawn() {
  throw new Error("child_process.spawn needs the I/O broker, spec 508");
}
