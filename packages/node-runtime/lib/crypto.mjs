// `crypto.*` (specs 035, 057, 060, 061, 467, 474). String-in/string-out
// digests return lowercase hex; `sha1Bytes` returns the raw digest as a
// byte string; `randomKey`/`encrypt`/`decrypt` are AES-256-GCM over strings
// with a base64 envelope; the `*Sync` family and the `createHash`/
// `createHmac` builders work on `Buffer`s. Failure values follow the native
// runtime: "" or an empty buffer, and a wrong-length key throws.
import { Buffer } from "node:buffer";
import ncrypto from "node:crypto";
import { toBuffer, fromBuffer } from "./lang.mjs";
import { Buffer as LumenBuffer } from "./buffer.mjs";

const KEY_LENGTH = 32;
const NONCE_LENGTH = 12;
const TAG_LENGTH = 16;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function asBytes(b) {
  return b instanceof Uint8Array ? Buffer.from(b.buffer, b.byteOffset, b.byteLength) : toBuffer(String(b));
}

function lumen(nodeBuf) {
  return LumenBuffer.from(nodeBuf);
}

export function randomBytes(n) {
  const count = Math.max(Number(n) | 0, 0);
  return ncrypto.randomBytes(count).toString("hex");
}

export function randomUUID() {
  return ncrypto.randomUUID();
}

export function sha256(data) {
  return ncrypto.createHash("sha256").update(toBuffer(data)).digest("hex");
}

export function sha1(data) {
  return ncrypto.createHash("sha1").update(toBuffer(data)).digest("hex");
}

/** The raw 20 digest bytes as a byte string (spec 474: the WebSocket
 *  handshake feeds them to `base64Encode`). */
export function sha1Bytes(data) {
  return ncrypto.createHash("sha1").update(toBuffer(data)).digest().toString("latin1");
}

export function base64Encode(data) {
  return toBuffer(data).toString("base64");
}

/** Standard base64 with padding; anything else decodes to "" (spec 474). */
export function base64Decode(text) {
  if (!BASE64.test(text)) return "";
  return fromBuffer(Buffer.from(text, "base64"));
}

/** A 32-byte key travels in a string as its bytes, one code unit each, in
 *  either string mode — `randomKey()` makes one that way. */
function requireKey(key) {
  const k = Buffer.from(key, "latin1");
  if (k.length !== KEY_LENGTH) throw new Error("crypto key must be exactly 32 bytes");
  return k;
}

export function randomKey() {
  return ncrypto.randomBytes(KEY_LENGTH).toString("latin1");
}

/** `encrypt(plaintext, key)` (spec 467): base64 of nonce || ciphertext || tag. */
export function encrypt(plaintext, key) {
  const k = requireKey(key);
  const nonce = ncrypto.randomBytes(NONCE_LENGTH);
  const cipher = ncrypto.createCipheriv("aes-256-gcm", k, nonce);
  const ct = Buffer.concat([cipher.update(toBuffer(plaintext)), cipher.final()]);
  return Buffer.concat([nonce, ct, cipher.getAuthTag()]).toString("base64");
}

/** `decrypt(envelope, key)`: the plaintext, or "" for an envelope this key
 *  did not produce. */
export function decrypt(envelope, key) {
  const k = requireKey(key);
  if (!BASE64.test(envelope)) return "";
  const raw = Buffer.from(envelope, "base64");
  if (raw.length < NONCE_LENGTH + TAG_LENGTH) return "";
  const nonce = raw.subarray(0, NONCE_LENGTH);
  const ct = raw.subarray(NONCE_LENGTH, raw.length - TAG_LENGTH);
  const tag = raw.subarray(raw.length - TAG_LENGTH);
  try {
    const d = ncrypto.createDecipheriv("aes-256-gcm", k, nonce);
    d.setAuthTag(tag);
    return fromBuffer(Buffer.concat([d.update(ct), d.final()]));
  } catch {
    return "";
  }
}

export function randomBytesBuffer(n) {
  return lumen(ncrypto.randomBytes(Math.max(Number(n) | 0, 0)));
}

/** HMAC-SHA256 of `data` under `key` (spec 057). */
export function hmacSync(key, data) {
  return lumen(ncrypto.createHmac("sha256", asBytes(key)).update(asBytes(data)).digest());
}

/** AES-256-GCM: ciphertext || tag; an empty buffer for a key that is not 32
 *  bytes or an IV that is not 12 (spec 057). */
export function encryptSync(key, iv, data) {
  const k = asBytes(key), n = asBytes(iv);
  if (k.length !== KEY_LENGTH || n.length !== NONCE_LENGTH) return LumenBuffer.alloc(0);
  const c = ncrypto.createCipheriv("aes-256-gcm", k, n);
  const ct = Buffer.concat([c.update(asBytes(data)), c.final()]);
  return lumen(Buffer.concat([ct, c.getAuthTag()]));
}

export function decryptSync(key, iv, data) {
  const k = asBytes(key), n = asBytes(iv), d = asBytes(data);
  if (k.length !== KEY_LENGTH || n.length !== NONCE_LENGTH || d.length < TAG_LENGTH) return LumenBuffer.alloc(0);
  try {
    const dec = ncrypto.createDecipheriv("aes-256-gcm", k, n);
    dec.setAuthTag(d.subarray(d.length - TAG_LENGTH));
    return lumen(Buffer.concat([dec.update(d.subarray(0, d.length - TAG_LENGTH)), dec.final()]));
  } catch {
    return LumenBuffer.alloc(0);
  }
}

/** PBKDF2-HMAC-SHA256 (spec 061); empty for `iterations < 1` or `keylen <= 0`. */
export function pbkdf2Sync(password, salt, iterations, keylen) {
  const it = Number(iterations) | 0, kl = Number(keylen) | 0;
  if (it < 1 || kl <= 0) return LumenBuffer.alloc(0);
  return lumen(ncrypto.pbkdf2Sync(asBytes(password), asBytes(salt), it, kl, "sha256"));
}

/** scrypt with N=2^14, r=8, p=1 (spec 061); empty for `keylen <= 0`. */
export function scryptSync(password, salt, keylen) {
  const kl = Number(keylen) | 0;
  if (kl <= 0) return LumenBuffer.alloc(0);
  return lumen(ncrypto.scryptSync(asBytes(password), asBytes(salt), kl, { N: 16384, r: 8, p: 1 }));
}

/** Constant-time equality; buffers of different lengths are unequal, not an error. */
export function timingSafeEqual(a, b) {
  const x = asBytes(a), y = asBytes(b);
  if (x.length !== y.length) return false;
  return ncrypto.timingSafeEqual(x, y);
}

const HASH_ALGORITHMS = new Set(["md5", "sha1", "sha256", "sha512"]);

function algorithm(name) {
  // The native builders know four algorithms and fall back to sha256.
  return HASH_ALGORITHMS.has(name) ? name : "sha256";
}

class Hash {
  #h;
  constructor(h) { this.#h = h; }
  update(data) { this.#h.update(asBytes(data)); return this; }
  digest() { return lumen(this.#h.digest()); }
}

export class Hmac extends Hash {}
export { Hash };

/** `createHash(algorithm)` (spec 060): md5, sha1, sha256, sha512. */
export function createHash(name) {
  return new Hash(ncrypto.createHash(algorithm(name)));
}

export function createHmac(name, key) {
  return new Hmac(ncrypto.createHmac(algorithm(name), asBytes(key)));
}
