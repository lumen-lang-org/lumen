// `fs.*` (specs 031, 038, 044, 046, 047) in Lumen's shapes: string results,
// `mkdirSync(path, recursive: bool)`, `statSync` as a record of plain fields,
// `readSync(fd, n)` returning the bytes read, streams with `read`/`readLine`.
//
// Failure behaviour follows the native runtime (src/lumen_runtime_fs.zig),
// not Node's: the writing calls that Lumen makes throw (`readFileSync`,
// `writeFileSync`, `appendFileSync`, `mkdirSync`, `unlinkSync`, `renameSync`,
// `copyFileSync`) with the native message shape, and everything else falls
// back to "", -1, false, [] or a zero record.
import { Buffer } from "node:buffer";
import nfs from "node:fs";
import { hrtime } from "node:process";
import { bytes, text, toBuffer, fromBuffer } from "./lang.mjs";
import { ReadableStream, WritableStream } from "./streams.mjs";

export { ReadableStream, WritableStream };

const ZERO_STAT = Object.freeze({ size: 0, isFile: false, isDirectory: false, mtimeMs: 0 });

function fail(what, path, e) {
  return new Error(`cannot ${what} '${path}': ${e && e.code ? e.code : "Unexpected"}`);
}

/** Node's Stats -> Lumen's `{ size, isFile, isDirectory, mtimeMs }` (spec 031:
 *  the two numbers are `int`, truncated exactly as the native record is). */
function statRecord(st) {
  return {
    size: Number(st.size) | 0,
    isFile: st.isFile(),
    isDirectory: st.isDirectory(),
    mtimeMs: Math.trunc(st.mtimeMs) | 0,
  };
}

function toMs(ms) {
  return Number(ms) / 1000;
}

function tryStat(fn) {
  try { return statRecord(fn()); } catch { return { ...ZERO_STAT }; }
}

export function readFileSync(path, encoding) {
  void encoding; // a Lumen string is bytes; the encoding is accepted for the Node-shaped call
  try { return fromBuffer(nfs.readFileSync(text(path))); } catch (e) { throw fail("read", path, e); }
}

export function existsSync(path) {
  try { nfs.accessSync(text(path)); return true; } catch { return false; }
}

export function realpathSync(path) {
  try { return bytes(nfs.realpathSync(text(path))); } catch { return path; }
}

export function writeFileSync(path, data) {
  try { nfs.writeFileSync(text(path), toBuffer(data)); } catch (e) { throw fail("write", path, e); }
}

export function appendFileSync(path, data) {
  try { nfs.appendFileSync(text(path), toBuffer(data)); } catch (e) { throw fail("append to", path, e); }
}

export function mkdirSync(path, recursive = false) {
  try {
    nfs.mkdirSync(text(path), { recursive: !!recursive });
  } catch (e) {
    if (!recursive && e.code === "EEXIST") return;
    throw fail("make", path, e);
  }
}

export function unlinkSync(path) {
  try { nfs.unlinkSync(text(path)); } catch (e) { throw fail("delete", path, e); }
}

export function renameSync(from, to) {
  try { nfs.renameSync(text(from), text(to)); } catch (e) {
    throw new Error(`cannot rename '${from}' to '${to}': ${e.code ?? "Unexpected"}`);
  }
}

export function copyFileSync(from, to) {
  try { nfs.copyFileSync(text(from), text(to)); } catch (e) {
    throw new Error(`cannot copy '${from}' to '${to}': ${e.code ?? "Unexpected"}`);
  }
}

export function rmdirSync(path) {
  try { nfs.rmdirSync(text(path)); } catch {}
}

export function rmSync(path, recursive = false) {
  try { nfs.rmSync(text(path), { recursive: !!recursive, force: false }); } catch {}
}

export function truncateSync(path, len) {
  try { nfs.truncateSync(text(path), Number(len)); } catch {}
}

export function linkSync(existing, link) {
  try { nfs.linkSync(text(existing), text(link)); } catch {}
}

export function symlinkSync(target, path) {
  try { nfs.symlinkSync(text(target), text(path)); } catch {}
}

export function readlinkSync(path) {
  try { return bytes(nfs.readlinkSync(text(path))); } catch { return ""; }
}

export function chmodSync(path, mode) {
  try { nfs.chmodSync(text(path), Number(mode)); } catch {}
}

export function accessSync(path, mode = 0) {
  const m = Number(mode);
  let flags = nfs.constants.F_OK;
  if (m & 4) flags |= nfs.constants.R_OK;
  if (m & 2) flags |= nfs.constants.W_OK;
  if (m & 1) flags |= nfs.constants.X_OK;
  try { nfs.accessSync(text(path), flags); return true; } catch { return false; }
}

export function cpSync(from, to, recursive = false) {
  try { nfs.cpSync(text(from), text(to), { recursive: !!recursive }); } catch {}
}

let mkdtempCounter = 0;
export function mkdtempSync(prefix) {
  // The native suffix is eight hex digits of clock mixed with a counter; the
  // shape (prefix + 8 hex chars) is what a program can see, so keep it.
  mkdtempCounter += 1;
  const mixed = (Number(hrtime.bigint() & 0xffffffffn) ^ Math.imul(mkdtempCounter, 2654435761)) >>> 0;
  const path = prefix + mixed.toString(16).padStart(8, "0");
  try { nfs.mkdirSync(text(path)); } catch { return ""; }
  return path;
}

export function statSync(path) {
  return tryStat(() => nfs.statSync(text(path)));
}

export function lstatSync(path) {
  return tryStat(() => nfs.lstatSync(text(path)));
}

export function fstatSync(fd) {
  return tryStat(() => nfs.fstatSync(fd));
}

/** `openSync(path, flags)`: "w" truncates, "a" appends, anything else reads;
 *  -1 when the file cannot be opened (spec 031). */
export function openSync(path, flags) {
  const mode = flags === "w" ? "w" : flags === "a" ? "a" : "r";
  try { return nfs.openSync(text(path), mode); } catch { return -1; }
}

export function closeSync(fd) {
  try { nfs.closeSync(fd); } catch {}
}

/** `readSync(fd, n)`: up to `n` bytes as a string; "" at end of file, on a
 *  bad descriptor, or for `n <= 0`. Blocks like the native read. */
export function readSync(fd, len) {
  const n = Number(len);
  if (n <= 0 || fd < 0) return "";
  const buf = Buffer.alloc(n);
  for (;;) {
    try {
      const k = nfs.readSync(fd, buf, 0, n, null);
      return fromBuffer(buf.subarray(0, k));
    } catch (e) {
      if (e.code === "EAGAIN") { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1); continue; }
      return "";
    }
  }
}

/** `writeSync(fd, data)`: the byte count written, 0 on failure. */
export function writeSync(fd, data) {
  if (fd < 0) return 0;
  const buf = toBuffer(data);
  let off = 0;
  while (off < buf.length) {
    try { off += nfs.writeSync(fd, buf, off, buf.length - off); } catch (e) {
      if (e.code === "EAGAIN") { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1); continue; }
      return 0;
    }
  }
  return buf.length;
}

export function fchmodSync(fd, mode) {
  try { nfs.fchmodSync(fd, Number(mode)); } catch {}
}

export function lchmodSync(path, mode) {
  try { nfs.lchmodSync ? nfs.lchmodSync(text(path), Number(mode)) : nfs.chmodSync(text(path), Number(mode)); } catch {}
}

export function fchownSync(fd, uid, gid) {
  try { nfs.fchownSync(fd, Number(uid), Number(gid)); } catch {}
}

export function chownSync(path, uid, gid) {
  try { nfs.chownSync(text(path), Number(uid), Number(gid)); } catch {}
}

export function lchownSync(path, uid, gid) {
  try { nfs.lchownSync(text(path), Number(uid), Number(gid)); } catch {}
}

/** `writevSync(fd, chunks)`: one vectored write; the byte count, 0 on failure. */
export function writevSync(fd, bufs) {
  if (fd < 0) return 0;
  try { return nfs.writevSync(fd, bufs.map(toBuffer)); } catch { return 0; }
}

/** `readvSync(fd, sizes)`: one vectored read into buffers of the given
 *  sizes; each result string holds what its buffer received (spec 031). */
export function readvSync(fd, sizes) {
  if (fd < 0) return [];
  const bufs = sizes.map((n) => Buffer.alloc(Math.max(Number(n), 0)));
  let got;
  try { got = nfs.readvSync(fd, bufs); } catch { return []; }
  const out = [];
  let remaining = got;
  for (const b of bufs) {
    const take = Math.min(b.length, remaining);
    out.push(fromBuffer(b.subarray(0, take)));
    remaining -= take;
  }
  return out;
}

export function fsyncSync(fd) {
  try { nfs.fsyncSync(fd); } catch {}
}

export function fdatasyncSync(fd) {
  try { nfs.fdatasyncSync(fd); } catch {}
}

export function ftruncateSync(fd, len) {
  try { nfs.ftruncateSync(fd, Number(len)); } catch {}
}

export function futimesSync(fd, atimeMs, mtimeMs) {
  try { nfs.futimesSync(fd, toMs(atimeMs), toMs(mtimeMs)); } catch {}
}

export function utimesSync(path, atimeMs, mtimeMs) {
  try { nfs.utimesSync(text(path), toMs(atimeMs), toMs(mtimeMs)); } catch {}
}

export function lutimesSync(path, atimeMs, mtimeMs) {
  try { nfs.lutimesSync(text(path), toMs(atimeMs), toMs(mtimeMs)); } catch {}
}

export function readdirSync(path) {
  try { return nfs.readdirSync(text(path)).map(bytes); } catch { return []; }
}

/** `fs.watch(path, (name, event) => ...)` (spec 044): `event` is "change"
 *  or "rename". Natively this call never returns; here the watcher keeps the
 *  process alive and the listener runs from the event loop. */
export function watch(path, listener) {
  const w = nfs.watch(text(path), (eventType, filename) => {
    listener(filename ? bytes(String(filename)) : path, eventType === "change" ? "change" : "rename");
  });
  w.on("error", () => {});
  return w;
}

export function createReadStream(path) {
  let fd = -1;
  try { fd = nfs.openSync(text(path), "r"); } catch {}
  return new ReadableStream(fd);
}

export function createWriteStream(path) {
  let fd = -1;
  try { fd = nfs.openSync(text(path), "w"); } catch {}
  return new WritableStream(fd);
}

// The async set (spec 047): the same fallbacks as their sync twins.
export async function readFile(path) {
  try { return fromBuffer(await nfs.promises.readFile(text(path))); } catch { return ""; }
}

export async function writeFile(path, data) {
  try { await nfs.promises.writeFile(text(path), toBuffer(data)); } catch {}
}

export async function appendFile(path, data) {
  try { await nfs.promises.appendFile(text(path), toBuffer(data)); } catch {}
}

export async function unlink(path) {
  try { await nfs.promises.unlink(text(path)); } catch {}
}

export async function mkdir(path) {
  try { await nfs.promises.mkdir(text(path)); } catch {}
}

export async function rmdir(path) {
  try { await nfs.promises.rmdir(text(path)); } catch {}
}

export async function stat(path) {
  try { return statRecord(await nfs.promises.stat(text(path))); } catch { return { ...ZERO_STAT }; }
}
