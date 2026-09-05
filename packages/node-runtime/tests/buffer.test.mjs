import { test } from "node:test";
import assert from "node:assert/strict";
import { Buffer as LBuffer } from "../lib/buffer.mjs";

test("from/alloc/length (spec 056): from(s) holds the string's bytes", () => {
  const b = LBuffer.from("h\xc3\xa9");
  assert.ok(b instanceof Uint8Array);
  assert.equal(b.length, 3);
  assert.deepEqual([...b], [0x68, 0xc3, 0xa9]);
  assert.deepEqual([...LBuffer.from("68c3a9", "hex")], [0x68, 0xc3, 0xa9]);
  assert.deepEqual([...LBuffer.from("aMOp", "base64")], [0x68, 0xc3, 0xa9]);
  assert.equal(LBuffer.from("abc", "hex").length, 0);
  assert.equal(LBuffer.from("zz", "hex").length, 0);
  assert.equal(LBuffer.from("a-", "base64").length, 0);
  assert.equal(LBuffer.from("h\xc3\xa9", "utf8").length, 3);
  const z = LBuffer.alloc(4);
  assert.deepEqual([...z], [0, 0, 0, 0]);
  assert.equal(LBuffer.alloc(-2).length, 0);
  assert.deepEqual([...LBuffer.from([1, 2])], [1, 2]);
});

test("toString: hex, base64, otherwise the raw bytes as a string", () => {
  const b = LBuffer.from("h\xc3\xa9");
  assert.equal(b.toString("hex"), "68c3a9");
  assert.equal(b.toString("base64"), "aMOp");
  assert.equal(b.toString("utf8"), "h\xc3\xa9");
  assert.equal(b.toString(""), "h\xc3\xa9");
});

test("at is 0 out of range; slice clamps; equals compares bytes", () => {
  const b = LBuffer.from("abcdef");
  assert.equal(b.at(0), 0x61);
  assert.equal(b.at(5), 0x66);
  assert.equal(b.at(6), 0);
  assert.equal(b.at(-1), 0);
  assert.equal(b.slice(1, 3).toString(""), "bc");
  assert.equal(b.slice(-5, 100).toString(""), "abcdef");
  assert.equal(b.slice(4, 2).length, 0);
  assert.ok(b.slice(0, 2) instanceof LBuffer);
  assert.equal(b.equals(LBuffer.from("abcdef")), true);
  assert.equal(b.equals(LBuffer.from("abcdeg")), false);
  assert.equal(b.equals(LBuffer.from("abc")), false);
  assert.equal(LBuffer.isBuffer(b), true);
});
