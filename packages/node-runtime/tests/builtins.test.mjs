import { test } from "node:test";
import assert from "node:assert/strict";
import * as B from "../lib/builtins.mjs";
import { runProgram } from "./helpers.mjs";

test("Math.clamp/exp2 and the constants as calls that still read as numbers", () => {
  assert.equal(B.Math.clamp(5, 1, 3), 3);
  assert.equal(B.Math.clamp(-5, 1, 3), 1);
  assert.equal(B.Math.clamp(2, 1, 3), 2);
  assert.equal(B.Math.exp2(10), 1024);
  assert.equal(B.Math.PI(), globalThis.Math.PI);
  assert.equal(B.Math.PI * 2, globalThis.Math.PI * 2);
  assert.equal(`${B.Math.E}`, String(globalThis.Math.E));
  assert.equal(B.Math.abs(-1), 1);
});

test("String.contains/startsWith/isEmpty/compare; fromCodePoint yields bytes", () => {
  assert.equal(B.String.contains("hello", "ell"), true);
  assert.equal(B.String.contains("hello", "z"), false);
  assert.equal(B.String.startsWith("hello", "he"), true);
  assert.equal(B.String.isEmpty(""), true);
  assert.equal(B.String.isEmpty("a"), false);
  assert.deepEqual([B.String.compare("a", "b"), B.String.compare("b", "b"), B.String.compare("c", "b")], [-1, 0, 1]);
  assert.equal(B.String.fromCodePoint(0xe9), "\xc3\xa9");
  assert.equal(B.String.fromCodePoint(72, 105), "Hi");
  assert.equal(B.String.fromCodePoint(0xd800), "\xef\xbf\xbd");
  assert.equal(B.String.fromCharCode(65), "A");
  assert.equal(B.String.fromCharCode(300), "\x2c");
  assert.equal(B.String.fromCharCode(195, 169), "\xc3\xa9");
  assert.equal(B.Array.isEmpty([]), true);
  assert.equal(B.Array.isEmpty([1]), false);
  assert.equal(B.Array.isArray([]), true);
});

test("Number.parseInt/parseFloat return null, never NaN; a value past 32 bits is null (spec 049)", () => {
  assert.equal(B.Number.parseInt("42"), 42);
  assert.equal(B.Number.parseInt("  -17rest"), -17);
  assert.equal(B.Number.parseInt("0x1f", 16), 31);
  assert.equal(B.Number.parseInt("ff", 16), 255);
  assert.equal(B.Number.parseInt("abc"), null);
  assert.equal(B.Number.parseInt(""), null);
  assert.equal(B.Number.parseInt("99999999999"), null);
  assert.equal(B.Number.parseInt("2147483647"), 2147483647);
  assert.equal(B.Number.parseInt("-2147483648"), -2147483648);
  assert.equal(B.Number.parseInt("2147483648"), null);
  assert.equal(B.Number.parseInt("10", 1), null);
  assert.equal(B.Number.parseFloat("3.5kg"), 3.5);
  assert.equal(B.Number.parseFloat(" -1e3"), -1000);
  assert.equal(B.Number.parseFloat("1e"), 1);
  assert.equal(B.Number.parseFloat("x"), null);
  assert.equal(B.Number.EPSILON(), globalThis.Number.EPSILON);
  assert.equal(B.Number.isInteger(3), true);
  assert.equal(B.JSON.parseOpen('{"a":1,"b":2}').a, 1);
  assert.equal(B.JSON.parse('["\\u00e9"]')[0], "\xc3\xa9");
  assert.equal(B.JSON.stringify({ a: 1 }), '{"a":1}');
  assert.equal(B.JSON.stringify(["\xc3\xa9"]), '["\xc3\xa9"]');
});

test("the overlays do not touch the real builtins; installBuiltins does", () => {
  assert.equal(typeof globalThis.Math.clamp, "undefined");
  assert.equal(typeof globalThis.Math.PI, "number");
  const r = runProgram('console.log(Math.clamp(9, 0, 5), Math.PI() > 3, Math.PI * 0 === 0, String.contains("ab", "b"), Number.parseInt("z"), typeof Math.sqrt(4), Number("7") + 1, Number.isInteger(2), Number.EPSILON() > 0, (5).toFixed(1), Number.MAX_SAFE_INTEGER > 1, JSON.parseOpen("[1]")[0], Array.isEmpty([]), typeof Number, String.fromCodePoint(233).length, JSON.parse("[\\"\\\\u00e9\\"]")[0].length);');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "5 true true true null number 8 true true 5.0 true 1 true function 2 2\n");
});
