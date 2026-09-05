import { test } from "node:test";
import assert from "node:assert/strict";
import ncrypto from "node:crypto";
import * as crypto from "../lib/crypto.mjs";
import { Buffer as LBuffer } from "../lib/buffer.mjs";

test("digests are lowercase hex over the string's bytes (specs 035, 474)", () => {
  assert.equal(crypto.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert.equal(crypto.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  assert.equal(crypto.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
  const raw = crypto.sha1Bytes("abc");
  assert.equal(raw.length, 20);
  assert.equal(Buffer.from(raw, "latin1").toString("hex"), crypto.sha1("abc"));
});

test("base64Encode/Decode; anything but padded standard base64 decodes to \"\"", () => {
  assert.equal(crypto.base64Encode("hi"), "aGk=");
  assert.equal(crypto.base64Encode("\xff\x00"), "/wA=");
  assert.equal(crypto.base64Decode("aGk="), "hi");
  assert.equal(crypto.base64Decode("/wA="), "\xff\x00");
  assert.equal(crypto.base64Decode("aGk"), "");
  assert.equal(crypto.base64Decode("a-k="), "");
  assert.equal(crypto.base64Decode(""), "");
});

test("randomBytes(n) is 2n hex chars, randomUUID is v4-shaped", () => {
  assert.match(crypto.randomBytes(4), /^[0-9a-f]{8}$/);
  assert.equal(crypto.randomBytes(0), "");
  assert.equal(crypto.randomBytes(-3), "");
  assert.match(crypto.randomUUID(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("randomKey/encrypt/decrypt (spec 467): AES-256-GCM, base64 envelope, \"\" on any mismatch", () => {
  const key = crypto.randomKey();
  assert.equal(key.length, 32);
  const env = crypto.encrypt("plain \xc3\xa9 text", key);
  assert.match(env, /^[A-Za-z0-9+/]+=*$/);
  assert.equal(Buffer.from(env, "base64").length, 12 + 13 + 16);
  assert.equal(crypto.decrypt(env, key), "plain \xc3\xa9 text");
  assert.notEqual(crypto.encrypt("x", key), crypto.encrypt("x", key));
  assert.equal(crypto.decrypt(env, crypto.randomKey()), "");
  const tampered = Buffer.from(env, "base64");
  tampered[12] ^= 1;
  assert.equal(crypto.decrypt(tampered.toString("base64"), key), "");
  assert.equal(crypto.decrypt("short", key), "");
  assert.equal(crypto.decrypt("!!!", key), "");
  assert.throws(() => crypto.encrypt("x", "tooshort"), /crypto key must be exactly 32 bytes/);
  assert.throws(() => crypto.decrypt(env, "tooshort"), /crypto key must be exactly 32 bytes/);
});

test("the Buffer family (spec 057): hmacSync, encryptSync/decryptSync, randomBytesBuffer", () => {
  const key = LBuffer.from("key");
  const mac = crypto.hmacSync(key, LBuffer.from("The quick brown fox jumps over the lazy dog"));
  assert.ok(mac instanceof LBuffer);
  assert.equal(mac.toString("hex"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
  const k = crypto.randomBytesBuffer(32), iv = crypto.randomBytesBuffer(12);
  assert.equal(k.length, 32);
  assert.equal(crypto.randomBytesBuffer(-1).length, 0);
  const ct = crypto.encryptSync(k, iv, LBuffer.from("message"));
  assert.equal(ct.length, 7 + 16);
  assert.equal(crypto.decryptSync(k, iv, ct).toString(""), "message");
  assert.equal(crypto.encryptSync(LBuffer.alloc(16), iv, ct).length, 0);
  assert.equal(crypto.encryptSync(k, LBuffer.alloc(16), ct).length, 0);
  assert.equal(crypto.decryptSync(k, iv, LBuffer.alloc(5)).length, 0);
  assert.equal(crypto.decryptSync(crypto.randomBytesBuffer(32), iv, ct).length, 0);
});

test("pbkdf2Sync is HMAC-SHA256, scryptSync is N=2^14 r=8 p=1; bad counts give an empty buffer (spec 061)", () => {
  const dk = crypto.pbkdf2Sync(LBuffer.from("password"), LBuffer.from("salt"), 1, 32);
  assert.equal(dk.toString("hex"), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
  assert.equal(crypto.pbkdf2Sync(LBuffer.from("p"), LBuffer.from("s"), 0, 32).length, 0);
  assert.equal(crypto.pbkdf2Sync(LBuffer.from("p"), LBuffer.from("s"), 1, 0).length, 0);
  const sk = crypto.scryptSync(LBuffer.from("password"), LBuffer.from("NaCl"), 16);
  assert.equal(sk.toString("hex"), ncrypto.scryptSync("password", "NaCl", 16, { N: 16384, r: 8, p: 1 }).toString("hex"));
  assert.equal(crypto.scryptSync(LBuffer.from("p"), LBuffer.from("s"), 0).length, 0);
});

test("timingSafeEqual: unequal lengths are false, not an error", () => {
  assert.equal(crypto.timingSafeEqual(LBuffer.from("abc"), LBuffer.from("abc")), true);
  assert.equal(crypto.timingSafeEqual(LBuffer.from("abc"), LBuffer.from("abd")), false);
  assert.equal(crypto.timingSafeEqual(LBuffer.from("a"), LBuffer.from("ab")), false);
});

test("createHash/createHmac builders chain; an unknown algorithm is sha256 (spec 060)", () => {
  const h = crypto.createHash("sha256");
  assert.equal(h.update(LBuffer.from("a")), h);
  assert.equal(h.update(LBuffer.from("bc")).digest().toString("hex"), crypto.sha256("abc"));
  assert.equal(crypto.createHash("nope").update(LBuffer.from("abc")).digest().toString("hex"), crypto.sha256("abc"));
  assert.equal(crypto.createHash("md5").update(LBuffer.from("abc")).digest().toString("hex"), "900150983cd24fb0d6963f7d28e17f72");
  assert.equal(crypto.createHash("sha1").update(LBuffer.from("abc")).digest().toString("hex"), crypto.sha1("abc"));
  assert.equal(crypto.createHash("sha512").update(LBuffer.from("abc")).digest().length, 64);
  const m = crypto.createHmac("sha256", LBuffer.from("key")).update(LBuffer.from("The quick brown fox jumps over the lazy dog")).digest();
  assert.equal(m.toString("hex"), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
});
