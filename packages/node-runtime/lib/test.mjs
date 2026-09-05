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
// body ends. Matchers map to `node:assert` so a failure shows both values.
import nassert from "node:assert/strict";
import { env } from "node:process";

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

function failExpectFalse() {
  return new nassert.AssertionError({ message: "expect(false)", actual: false, expected: true, operator: "expect" });
}

function flush(run) {
  if (unclaimedFalse(run)) throw failExpectFalse();
}

class Expectation {
  #entry;
  constructor(entry) { this.#entry = entry; }
  toBe(expected) {
    this.#entry.claimed = true;
    nassert.strictEqual(this.#entry.value, expected);
  }
  toEqual(expected) {
    this.#entry.claimed = true;
    nassert.deepStrictEqual(this.#entry.value, expected);
  }
}

export function expect(value) {
  const run = current ?? fallback;
  flush(run);
  const entry = { value, claimed: false };
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
