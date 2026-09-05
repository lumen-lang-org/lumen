import { test } from "node:test";
import assert from "node:assert/strict";
import { bytes, text, toBuffer, fromBuffer, divInt, defer, errorMessage, mode, __bytes, __text, __divInt } from "../lib/lang.mjs";

test("the default representation is byte strings (spec 505 decision 1)", () => {
  assert.equal(mode, "bytes");
  const s = bytes("é");
  assert.equal(s.length, 2);
  assert.equal(s.charCodeAt(0), 0xc3);
  assert.equal(s.charCodeAt(1), 0xa9);
  assert.equal(text(s), "é");
});

test("toBuffer/fromBuffer cross the boundary as latin1, never utf8 (FR-002)", () => {
  const s = "\xc3\xa9";
  const b = toBuffer(s);
  assert.equal(b.length, 2);
  assert.deepEqual([...b], [0xc3, 0xa9]);
  assert.equal(fromBuffer(b), s);
  assert.equal(fromBuffer(new Uint8Array([0x41, 0xff])), "A\xff");
});

test("divInt truncates toward zero and rejects a zero divisor (spec 137)", () => {
  assert.equal(divInt(7, 2), 3);
  assert.equal(divInt(-7, 2), -3);
  assert.equal(divInt(7, -2), -3);
  assert.throws(() => divInt(1, 0), RangeError);
});

test("defer hands `using` a disposable that runs the function once asked", () => {
  let ran = 0;
  const d = defer(() => { ran += 1; });
  assert.equal(ran, 0);
  d.dispose();
  d[Symbol.dispose]();
  assert.equal(ran, 2);
  assert.throws(() => defer(42), TypeError);
});

test("errorMessage reads whatever was thrown", () => {
  assert.equal(errorMessage(new Error("boom")), "boom");
  assert.equal(errorMessage("raw"), "raw");
  assert.equal(errorMessage(7), "");
});

test("the emitted-code aliases are the same functions", () => {
  assert.equal(__bytes, bytes);
  assert.equal(__text, text);
  assert.equal(__divInt, divInt);
});
