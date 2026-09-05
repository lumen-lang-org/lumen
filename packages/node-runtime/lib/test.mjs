// `test(name, fn)` and `expect` (specs 008, 028, 242, 243). Under the test
// runner (`node --test`, which sets NODE_TEST_CONTEXT in the file's process)
// a test registers with `node:test`; under a plain `node` run it is not
// executed, the way `lumen run` leaves `test` blocks out of the binary.
// `LUMEN_TEST=inline` is the third mode: each test runs as soon as it is
// declared and the tally lands in `globalThis.__t` (`{ pass, fail,
// failures }`), which is what spec 501's probe reads.
//
// `expect` has two forms the runtime cannot tell apart at the call:
// `expect(cond);` asserts a boolean, `expect(a).toBe(b)` compares. So a
// call records itself as pending; a matcher call claims it, and any
// unclaimed `expect(false)` fails at the next `expect` or when the test
// body ends. Matchers compare as `node:assert` does and fail with the line
// the native runner prints, `expected <b>, found <a>` (spec 242), so a
// failure reads the same on both targets.
import nassert from "node:assert/strict";
import { env } from "node:process";
import { inspect } from "node:util";
import { bytes, fmt, printable } from "./lang.mjs";

const INLINE = env.LUMEN_TEST === "inline";
const RUNNING_UNDER_TEST_RUNNER = !INLINE && (env.NODE_TEST_CONTEXT !== undefined || env.LUMEN_TEST === "1");

let nodeTest = null;
if (RUNNING_UNDER_TEST_RUNNER) {
  ({ test: nodeTest } = await import("node:test"));
}

/** The inline tally; only present under `LUMEN_TEST=inline`. */
export const tally = INLINE ? { pass: 0, fail: 0, failures: [] } : null;
if (INLINE) globalThis.__t = tally;

// The run whose body is executing: `expect` records into it. A body that
// awaits and then calls `expect` again lands in `fallback`, which the run
// drains when its promise settles.
let current = null;
const fallback = { pending: [] };

function unclaimedFalse(run) {
  const list = run.pending.splice(0);
  return list.find((p) => !p.claimed && p.value === false);
}

/** The failure of an unclaimed `expect(false)`, placed at the `expect` call
 *  itself: the failure surfaces later, but the call is where it happened. */
function failExpectFalse(entry) {
  const e = new nassert.AssertionError({ message: "expect(false)", actual: false, expected: true, operator: "expect" });
  e.stack = "AssertionError: expect(false)\n" + entry.frames;
  return e;
}

function flush(run) {
  const entry = unclaimedFalse(run);
  if (entry) throw failExpectFalse(entry);
}

/** The stack frames above an `expect` call, for placing its failure. */
function framesAbove() {
  const stack = new Error().stack ?? "";
  return stack.split("\n").slice(3).join("\n");
}

/** A value as the failure line shows it: a number the way the program
 *  would print it, a string quoted, anything else inspected. The result is a
 *  byte string like every message a program raises, so the reporter decodes
 *  each once. (`JSON.stringify` copies a byte string's code units and adds
 *  ASCII escapes only.) */
function show(v) {
  if (typeof v === "number") return fmt(v);
  if (typeof v === "string") return JSON.stringify(v);
  return bytes(inspect(printable(v)));
}

function mismatch(actual, expected) {
  return new nassert.AssertionError({
    message: "expected " + show(expected) + ", found " + show(actual),
    actual,
    expected,
    operator: "toBe",
  });
}

class Expectation {
  #entry;
  constructor(entry) { this.#entry = entry; }
  toBe(expected) {
    this.#entry.claimed = true;
    if (!Object.is(this.#entry.value, expected)) throw mismatch(this.#entry.value, expected);
  }
  toEqual(expected) {
    this.#entry.claimed = true;
    try {
      nassert.deepStrictEqual(this.#entry.value, expected);
    } catch (e) {
      if (!(e instanceof nassert.AssertionError)) throw e;
      throw mismatch(this.#entry.value, expected);
    }
  }
}

export function expect(value) {
  const run = current ?? fallback;
  flush(run);
  const entry = { value, claimed: false, frames: framesAbove() };
  run.pending.push(entry);
  return new Expectation(entry);
}

/** Runs one test body: the synchronous part under `current`, then any
 *  promise it returned; an unclaimed `expect(false)` fails it either way. */
function runBody(fn) {
  const run = { pending: [] };
  const prev = current;
  current = run;
  let result;
  try {
    result = fn();
  } finally {
    current = prev;
  }
  if (result && typeof result.then === "function") {
    return result.then(() => { flush(run); flush(fallback); });
  }
  flush(run);
  return undefined;
}

function recordInline(name, e) {
  if (e === undefined) { tally.pass += 1; return; }
  tally.fail += 1;
  tally.failures.push(name + ": " + (e && e.message ? e.message : String(e)));
}

export function test(name, fn) {
  if (INLINE) {
    let result;
    try { result = runBody(fn); } catch (e) { recordInline(name, e); return; }
    if (result) result.then(() => recordInline(name, undefined), (e) => recordInline(name, e));
    else recordInline(name, undefined);
    return;
  }
  if (!nodeTest) return;
  nodeTest(name, () => runBody(fn));
}
