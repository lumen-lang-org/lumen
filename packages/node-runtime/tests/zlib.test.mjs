import { test } from "node:test";
import assert from "node:assert/strict";
import nzlib from "node:zlib";
import * as zlib from "../lib/zlib.mjs";

test("gzip/gunzip and deflate/inflate round-trip byte strings (spec 039)", () => {
  const data = "hello \xc3\xa9 hello hello".repeat(20);
  const gz = zlib.gzipSync(data);
  assert.equal(gz.charCodeAt(0), 0x1f);
  assert.equal(gz.charCodeAt(1), 0x8b);
  assert.equal(zlib.gunzipSync(gz), data);
  const df = zlib.deflateSync(data);
  assert.ok(df.length < data.length);
  assert.equal(zlib.inflateSync(df), data);
});

test("deflate is the raw stream the native runtime emits (no zlib header)", () => {
  const df = zlib.deflateSync("abcabcabc");
  assert.equal(nzlib.inflateRawSync(Buffer.from(df, "latin1")).toString("latin1"), "abcabcabc");
  assert.throws(() => nzlib.inflateSync(Buffer.from(df, "latin1")));
});

test("an undecodable stream yields \"\"", () => {
  assert.equal(zlib.gunzipSync("not gzip"), "");
  assert.equal(zlib.inflateSync("\xff\xff\xff"), "");
  assert.equal(zlib.gunzipSync(""), "");
});
