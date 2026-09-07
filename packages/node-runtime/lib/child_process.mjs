// `child_process.*` (specs 037, 450). `spawnSync(cmd, args)` runs to
// completion with stdin ignored and returns `{ stdout, stderr, status }` as
// strings and an int: -1 when the command could not start or died by a
// signal. `spawn` keeps a process alive with blocking `readLine`, wired to
// the spec 508 I/O broker: mirrors `LumenChildProcess`
// (src/lumen_runtime_os.zig) exactly, including its "a failed spawn
// degrades to a no-op handle" fallback -- `spawn` never throws.
import ncp from "node:child_process";
import { text, fromBuffer, toBuffer } from "./lang.mjs";
import { DEAD_HANDLE, syncSpawn, syncReadLine, syncWrite, syncWriteLine, syncClose } from "./broker/sync_bridge.mjs";

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

class ChildProcess {
  #handle;
  constructor(handle) {
    this.#handle = handle;
  }
  /** Writes `data` to stdin verbatim; a no-op once closed, never spawned,
   *  or on a dead handle. */
  write(data) {
    if (this.#handle === DEAD_HANDLE) return;
    syncWrite(this.#handle, toBuffer(data));
  }
  /** Writes `data` then "\n". */
  writeLine(data) {
    if (this.#handle === DEAD_HANDLE) return;
    syncWriteLine(this.#handle, toBuffer(data));
  }
  /** The next "\n"-delimited stdout line, terminator kept (spec 450); ""
   *  at true end of stream, a dead handle, or once closed. */
  readLine() {
    if (this.#handle === DEAD_HANDLE) return "";
    return fromBuffer(syncReadLine(this.#handle));
  }
  /** Idempotent: flushes/closes stdin, then waits for the child to exit. */
  close() {
    if (this.#handle === DEAD_HANDLE) return;
    syncClose(this.#handle);
    this.#handle = DEAD_HANDLE;
  }
}

// `command`/`args` cross the broker as the Lumen (latin1-per-byte) strings
// they already are -- exactly like `net.connect`'s `host` -- and only
// become real JS text (`text(...)`, node:child_process's own expectation)
// on the broker side, right before the actual `child_process.spawn` call;
// see `broker.mjs`'s `opSpawn`. Converting here instead would double-decode
// non-ASCII bytes the way `Buffer.from(text(command), "latin1")` corrupts
// them.
export function spawn(command, args) {
  return new ChildProcess(syncSpawn(command, args));
}
