// The ReadableStream/WritableStream shapes of specs 046 and 053, shared by
// `fs.createReadStream`/`createWriteStream` and `process.stdin()`/`stdout()`/
// `stderr()`. Synchronous, blocking reads over a file descriptor via
// `fs.readSync`, exactly like the native runtime's std.Io.File reader.
import { Buffer } from "node:buffer";
import nfs from "node:fs";
import { fromBuffer, toBuffer } from "./lang.mjs";

const CHUNK = 65536;

function pause() {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
}

/** One blocking read into `buf`; -1 at end of stream or on any failure. A
 *  non-blocking descriptor (a pipe Node has already touched) is retried. */
function readOnce(fd, buf) {
  for (;;) {
    try {
      const n = nfs.readSync(fd, buf, 0, buf.length, null);
      return n === 0 ? -1 : n;
    } catch (e) {
      if (e.code === "EAGAIN") { pause(); continue; }
      if (e.code === "EOF") return -1;
      return -1;
    }
  }
}

export class ReadableStream {
  #fd;
  #buf = Buffer.alloc(0);
  #eof = false;
  #closeFd;
  constructor(fd, { closeFd = true } = {}) {
    this.#fd = fd;
    this.#closeFd = closeFd;
  }
  /** Reads the next chunk (up to 64 KiB); "" once the stream is exhausted or
   *  when it never opened (spec 046). */
  read() {
    if (this.#fd < 0) return "";
    if (this.#buf.length > 0) {
      const out = this.#buf;
      this.#buf = Buffer.alloc(0);
      return fromBuffer(out);
    }
    if (this.#eof) return "";
    const scratch = Buffer.alloc(CHUNK);
    const n = readOnce(this.#fd, scratch);
    if (n < 0) { this.#eof = true; return ""; }
    return fromBuffer(scratch.subarray(0, n));
  }
  /** Reads through the next "\n", keeping it (spec 053: a blank line is "\n",
   *  only true end-of-stream is ""); a final unterminated line is returned
   *  as is. */
  readLine() {
    if (this.#fd < 0) return "";
    for (;;) {
      const nl = this.#buf.indexOf(10);
      if (nl >= 0) {
        const line = this.#buf.subarray(0, nl + 1);
        this.#buf = Buffer.from(this.#buf.subarray(nl + 1));
        return fromBuffer(line);
      }
      if (this.#eof) {
        if (this.#buf.length === 0) return "";
        const rest = this.#buf;
        this.#buf = Buffer.alloc(0);
        return fromBuffer(rest);
      }
      const scratch = Buffer.alloc(CHUNK);
      const n = readOnce(this.#fd, scratch);
      if (n < 0) { this.#eof = true; continue; }
      this.#buf = this.#buf.length === 0 ? Buffer.from(scratch.subarray(0, n)) : Buffer.concat([this.#buf, scratch.subarray(0, n)]);
    }
  }
  close() {
    if (this.#fd < 0) return;
    if (this.#closeFd) { try { nfs.closeSync(this.#fd); } catch {} }
    this.#fd = -1;
  }
}

export class WritableStream {
  #fd;
  #closeFd;
  constructor(fd, { closeFd = true } = {}) {
    this.#fd = fd;
    this.#closeFd = closeFd;
  }
  /** Writes the chunk in full; a stream that never opened swallows it (spec 046). */
  write(chunk) {
    if (this.#fd < 0) return;
    const buf = toBuffer(chunk);
    let off = 0;
    while (off < buf.length) {
      try {
        off += nfs.writeSync(this.#fd, buf, off, buf.length - off);
      } catch (e) {
        if (e.code === "EAGAIN") { pause(); continue; }
        return;
      }
    }
  }
  close() {
    if (this.#fd < 0) return;
    if (this.#closeFd) { try { nfs.closeSync(this.#fd); } catch {} }
    this.#fd = -1;
  }
}
