// `Buffer` (spec 056): a byte array with Lumen's small surface — `from`,
// `alloc`, `length`, `toString(encoding)`, `at`, `slice`, `equals`. It is a
// `Uint8Array`, so Node's own crypto/zlib/fs calls accept it directly, but
// its methods follow the native runtime, not Node's Buffer: `from(s)` takes
// the string's bytes, an undecodable "hex"/"base64" input gives an empty
// buffer, `at` is 0 out of range, `slice` clamps instead of counting from
// the end, and `toString` with any encoding but "hex"/"base64" hands the raw
// bytes back as a string.
import { Buffer as NodeBuffer } from "node:buffer";
import { toBuffer, fromBuffer } from "./lang.mjs";

const HEX = /^(?:[0-9a-fA-F]{2})*$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function wrap(nodeBuf) {
  const b = new LumenBuffer(nodeBuf.length);
  b.set(nodeBuf);
  return b;
}

export class LumenBuffer extends Uint8Array {
  static from(source, encoding) {
    if (typeof source !== "string") return wrap(NodeBuffer.from(source));
    if (encoding === "hex") return HEX.test(source) ? wrap(NodeBuffer.from(source, "hex")) : new LumenBuffer(0);
    if (encoding === "base64") return BASE64.test(source) ? wrap(NodeBuffer.from(source, "base64")) : new LumenBuffer(0);
    return wrap(toBuffer(source));
  }

  static alloc(n) {
    return new LumenBuffer(Math.max(Number(n) | 0, 0));
  }

  static isBuffer(v) {
    return v instanceof LumenBuffer;
  }

  toString(encoding = "") {
    const node = NodeBuffer.from(this.buffer, this.byteOffset, this.byteLength);
    if (encoding === "hex") return node.toString("hex");
    if (encoding === "base64") return node.toString("base64");
    return fromBuffer(node);
  }

  at(i) {
    const idx = Number(i);
    if (idx < 0 || idx >= this.length) return 0;
    return this[idx];
  }

  slice(start, end) {
    const len = this.length;
    let s = Math.min(Math.max(Number(start), 0), len);
    let e = Math.min(Math.max(Number(end), 0), len);
    if (e < s) e = s;
    return wrap(NodeBuffer.from(this.buffer, this.byteOffset + s, e - s));
  }

  equals(other) {
    if (other.length !== this.length) return false;
    for (let i = 0; i < this.length; i++) if (this[i] !== other[i]) return false;
    return true;
  }

  /** The bytes as a Node Buffer (no copy), for Node APIs that want one. */
  get node() {
    return NodeBuffer.from(this.buffer, this.byteOffset, this.byteLength);
  }
}

export { LumenBuffer as Buffer };
