import { test } from "node:test";
import assert from "node:assert/strict";
import { bytes, text, toBuffer, fromBuffer, divInt, defer, errorMessage, __bytes, __text, __divInt, fmt, charCodeAt, toUpperCase, toLowerCase, trim, trimStart, trimEnd, localeCompare, repeat, replace, replaceAll, jsonParse, printable, printArg, REVIVE } from "../lib/lang.mjs";

test("a string is its bytes, one code unit each (spec 505 decision 1)", () => {
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

test("the byte-semantics string methods answer what the native runtime answers (505 FR-001)", () => {
  assert.equal(charCodeAt("a", 0), 97);
  assert.equal(charCodeAt("a", 5), -1);
  assert.equal(charCodeAt("a", -1), -1);
  // ASCII case only: 0xE9 and 0xDF are bytes of UTF-8 sequences, not letters.
  assert.equal(toUpperCase("h\xc3\xa9llo \xc3\x9f"), "H\xc3\xa9LLO \xc3\x9f");
  assert.equal(toLowerCase("H\xc3\x89LLO"), "h\xc3\x89llo");
  // Space, tab, CR, LF only: 0xA0 (a byte of "à") stays.
  assert.equal(trim(" \t x\xa0 \r\n"), "x\xa0");
  assert.equal(trimStart("  x "), "x ");
  assert.equal(trimEnd("  x "), "  x");
  assert.deepEqual([localeCompare("a", "b"), localeCompare("b", "b"), localeCompare("\xc3", "b")], [-1, 0, 1]);
  assert.equal(repeat("ab", 2), "abab");
  assert.equal(repeat("ab", -1), "");
  assert.equal(replace("aXa", "X", "$&$&"), "a$&$&a");
  assert.equal(replace("abc", "", "x"), "abc");
  assert.equal(replace("abcb", "b", "-"), "a-cb");
  assert.equal(replaceAll("abcb", "b", "-"), "a-c-");
  assert.equal(replaceAll("abc", "", "x"), "abc");
});

test("JSON.parse takes bytes and answers bytes, escapes included; printable decodes for the console", () => {
  const doc = bytes('{"k\u00e9y": ["\\u00e9", "é", "\\ud83d\\ude80"], "n": 1, "o": {"s": "\\n"}}');
  const v = jsonParse(doc);
  const key = bytes("kéy");
  assert.deepEqual(Object.keys(v), [key, "n", "o"]);
  assert.deepEqual(v[key], ["\xc3\xa9", "\xc3\xa9", "\xf0\x9f\x9a\x80"]);
  assert.equal(v.n, 1);
  assert.equal(v.o.s, "\n");
  class P { constructor(name) { this.name = name; } }
  const shown = printable([bytes("é"), 1, { s: bytes("ü") }, new Map([[bytes("é"), new Set([bytes("ß")])]]), new P(bytes("é"))]);
  assert.equal(shown[0], "é");
  assert.equal(shown[2].s, "ü");
  assert.equal(shown[3].get("é").has("ß"), true);
  assert.ok(shown[4] instanceof P);
  assert.equal(shown[4].name, "é");
});

test("fmt prints a number as the native runtime does: every digit, no exponent, nan/inf (505 decision 2)", () => {
  assert.equal(fmt(1e21), "1000000000000000000000");
  assert.equal(fmt(-1.5e22), "-15000000000000000000000");
  assert.equal(fmt(1e-7), "0.0000001");
  assert.equal(fmt(1.23e-6), "0.00000123");
  assert.equal(fmt(1.5e21), "1500000000000000000000");
  assert.equal(fmt(1.2345e25), "12345000000000000000000000");
  assert.equal(fmt(0.1 + 0.2), "0.30000000000000004");
  assert.equal(fmt(100), "100");
  assert.equal(fmt(-2.5), "-2.5");
  assert.equal(fmt(-0), "-0");
  assert.equal(fmt(NaN), "nan");
  assert.equal(fmt(Infinity), "inf");
  assert.equal(fmt(-Infinity), "-inf");
  assert.equal(fmt(5e-324), "0." + "0".repeat(323) + "5");
  assert.equal(printArg(2.5e-5), "0.000025");
  assert.deepEqual(printArg([2.5e-5]), [2.5e-5]);
});

test("JSON.parse<T> checks the document against T's shape and blames the field the native parser names (specs 051, 483, 500)", () => {
  const ask = { f: { siteKey: "string", secret: "string", enabled: "bool", tries: "int" } };
  const why = (doc, open = false) => { try { jsonParse(doc, ask, open); return "parsed"; } catch (e) { return e.message; } };
  assert.equal(why('{"siteKey":"k","enabled":true,"tries":1}'), 'JSON.parse: the field "secret" is required and was not sent');
  assert.equal(why('{"siteKey":"k","secret":"s","enabled":true,"tries":1,"typo":2}'), 'JSON.parse: the field "typo" is not one this accepts');
  assert.equal(why('{"siteKey":"k","secret":"s","enabled":true,"tries":1,"typo":2}', true), "parsed");
  assert.equal(why('{"siteKey":"k","secret":"s","enabled":"yes","tries":1}'), 'JSON.parse: the field "enabled" wants a true or false');
  assert.equal(why('{"siteKey":"k","secret":"s","enabled":true,"tries":1.5}'), 'JSON.parse: the field "tries" wants a whole number');
  assert.equal(why('{"siteKey":"k","secret":"s","enabled":true,"tries":1}'), "parsed");
  assert.equal(why("not json at all"), "JSON.parse: invalid JSON (SyntaxError)");
  assert.equal(why('{"v":1'), "JSON.parse: invalid JSON (SyntaxError)");
  assert.equal(why('[1]'), "JSON.parse: invalid JSON (UnexpectedToken)");
  // Nested records and arrays are checked too; only the top level is blamed by name.
  const nested = { f: { items: { a: { f: { n: "int" } } }, note: { o: "string" } } };
  assert.equal(jsonParse('{"items":[{"n":1}]}', nested).note, null);
  assert.throws(() => jsonParse('{"items":[{"n":"x"}]}', nested), { message: "JSON.parse: invalid JSON (UnexpectedToken)" });
  assert.throws(() => jsonParse('{"items":[{"n":1,"extra":true}]}', nested), { message: "JSON.parse: invalid JSON (UnknownField)" });
  assert.equal(jsonParse('{"items":[{"n":1,"extra":true}]}', nested, true).items[0].extra, true);
  assert.deepEqual(jsonParse('{"items":[], "note": null}', nested), { items: [], note: null });
  assert.deepEqual(jsonParse('["a"]', { a: "string" }), ["a"]);
  assert.equal(jsonParse('{"anything": [1, "two"]}', "any").anything[1], "two");
});

test("JSON.parse<Class> revives an instance without running the constructor body (spec 456)", () => {
  // The classes are written as the emitter (spec 504) writes them: the
  // constructor returns before its body when handed `REVIVE`.
  let constructed = 0;
  class Agent {
    id = "";
    maxSteps = 0;
    constructor(id, maxSteps) { if (arguments[0] === REVIVE) return; constructed += 1; this.id = id; this.maxSteps = maxSteps; }
    describe() { return this.id + ":" + this.maxSteps; }
  }
  const shape = { c: Agent, f: { id: "string", maxSteps: "int" } };
  const back = jsonParse('{"id":"a1","maxSteps":5}', shape);
  assert.ok(back instanceof Agent);
  assert.equal(back.describe(), "a1:5");
  assert.equal(constructed, 0);
  const many = jsonParse('[{"id":"a","maxSteps":1}]', { a: shape });
  assert.equal(many[0].describe(), "a:1");
});

test("JSON.parse<Class> installs a #private field at its default, through the whole chain (spec 456, 504 T014)", () => {
  let constructed = 0;
  class Base {
    kind = "";
    #stamp = "";
    constructor(k) { if (arguments[0] === REVIVE) return; constructed += 1; this.kind = k; this.#stamp = "set:" + k; }
    stamp() { return this.#stamp; }
  }
  class Child extends Base {
    name = "";
    #token = "";
    constructor(k, n) { if (arguments[0] === REVIVE) { super(REVIVE); return; } super(k); constructed += 1; this.name = n; this.#token = "t:" + n; }
    reveal() { return this.#token; }
  }
  class Plain extends Base { note = "x"; }
  const child = jsonParse('{"kind":"animal","name":"rex"}', { c: Child, f: { kind: "string", name: "string" } });
  assert.ok(child instanceof Child);
  assert.equal(child.kind + "|" + child.name + "|[" + child.reveal() + "]|[" + child.stamp() + "]", "animal|rex|[]|[]");
  // A class without a constructor of its own forwards the sentinel through
  // JavaScript's default constructor.
  const plain = jsonParse('{"kind":"k","note":"n"}', { c: Plain, f: { kind: "string", note: "string" } });
  assert.equal(plain.note + "|" + plain.stamp(), "n|");
  assert.equal(constructed, 0);
  assert.equal(REVIVE, Symbol.for("lumen.revive"));
});
