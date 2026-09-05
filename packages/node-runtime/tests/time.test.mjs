import { test } from "node:test";
import assert from "node:assert/strict";
import * as time from "../lib/time.mjs";

test("now() is epoch milliseconds, monotonic() never goes backwards (spec 041)", () => {
  const n = time.now();
  assert.ok(Number.isInteger(n) && Math.abs(n - Date.now()) < 1000);
  const a = time.monotonic();
  const b = time.monotonic();
  assert.ok(Number.isInteger(a) && b >= a);
});
