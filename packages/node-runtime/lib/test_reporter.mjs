// The `lumen` reporter for `node --test` (spec 506): prints what the native
// `lumen test` prints (spec 242) -- one `ok <name>` / `FAIL <name> — <why>`
// line per test, `    at <file>:<line>` under a failure, and the tally --
// so a CI log reads alike whichever target ran the tests. The program's own
// stdout and stderr pass through as they arrive.
//
// `lumen test --target node` runs `node --test --test-reporter=<this file>
// --test-reporter-destination=stderr <entry>`; the results go to stderr as
// they do natively. `LUMEN_TEST_SOURCE` names the `.ts` file for the
// `<file>: no tests` line. Colour follows the native rule: a TTY without
// `NO_COLOR`.
import { env, stdout, stderr, cwd } from "node:process";
import { sep } from "node:path";
import { fileURLToPath } from "node:url";
import { text } from "./lang.mjs";

const color = stderr.isTTY && env.NO_COLOR === undefined;
const GREEN = "\x1b[32m", RED = "\x1b[1;31m", BOLD = "\x1b[1m", DIM = "\x1b[2m", CYAN = "\x1b[36m", RESET = "\x1b[0m";

/** The thrown error behind a `test:fail` event: Node wraps it in an
 *  `ERR_TEST_FAILURE` whose `cause` is the original. */
function thrown(details) {
  const e = details && details.error;
  return e && e.cause !== undefined ? e.cause : e;
}

/** The failure as the native runner words it: an assertion by its message,
 *  anything thrown as `Uncaught Error: <message>` (spec 243). */
function describe(e) {
  if (e == null) return "failed";
  if (e.code === "ERR_ASSERTION") return text(String(e.message));
  if (e instanceof Error) return "Uncaught Error: " + text(String(e.message));
  return "Uncaught " + text(String(e));
}

const RUNTIME_DIR = fileURLToPath(new URL("../", import.meta.url));

/** The first frame of the failure in the program's own code -- not Node's
 *  internals, not this package -- as `<path>:<line>`, the path relative to
 *  the working directory when it is under it; `null` when the stack has
 *  none. */
function location(e) {
  const stack = e && typeof e.stack === "string" ? e.stack : "";
  for (const line of stack.split("\n")) {
    if (/\bnode:/.test(line)) continue;
    const m = /\(?(?:file:\/\/)?(\/[^():\s]+):(\d+)(?::\d+)?\)?\s*$/.exec(line);
    if (!m || m[1].startsWith(RUNTIME_DIR)) continue;
    const here = cwd() + sep;
    return (m[1].startsWith(here) ? m[1].slice(here.length) : m[1]) + ":" + m[2];
  }
  return null;
}

/** Whether an event is `node --test`'s own entry for the file rather than
 *  a test in it: it is named by the file's path and placed at 1:1, where a
 *  generated module has only its header comment. A file with no tests
 *  passes as itself; one that fails to load fails as itself. */
function isFileEvent(data) {
  return data.line === 1 && data.column === 1 && typeof data.file === "string" && data.file.endsWith(data.name);
}

export default async function* lumenReporter(source) {
  let passed = 0;
  let failed = 0;
  let loaded = true;
  for await (const event of source) {
    if ((event.type === "test:pass" || event.type === "test:fail") && isFileEvent(event.data)) {
      if (event.type === "test:fail") {
        loaded = false;
        yield color ? `${RED}✗${RESET} ${env.LUMEN_TEST_SOURCE ?? event.data.name} — ${BOLD}the program did not load${RESET}\n` : `FAIL ${env.LUMEN_TEST_SOURCE ?? event.data.name} — the program did not load\n`;
      }
      continue;
    }
    switch (event.type) {
      case "test:stdout":
        stdout.write(event.data.message);
        break;
      case "test:stderr":
        stderr.write(event.data.message);
        break;
      case "test:pass":
        passed += 1;
        yield color ? `${GREEN}✓${RESET} ${event.data.name}\n` : `ok ${event.data.name}\n`;
        break;
      case "test:fail": {
        failed += 1;
        const e = thrown(event.data.details);
        const why = describe(e);
        yield color ? `${RED}✗${RESET} ${event.data.name} — ${BOLD}${why}${RESET}\n` : `FAIL ${event.data.name} — ${why}\n`;
        const at = location(e);
        if (at !== null) yield color ? `${DIM}    at ${RESET}${CYAN}${at}${RESET}\n` : `    at ${at}\n`;
        break;
      }
      default:
        break;
    }
  }
  if (!loaded) {
    yield color ? `${passed} passed, ${RED}${failed} failed${RESET}\n` : `${passed} passed, ${failed} failed\n`;
  } else if (passed === 0 && failed === 0) {
    yield `${env.LUMEN_TEST_SOURCE ?? "test"}: no tests\n`;
  } else if (failed === 0) {
    yield color ? `${GREEN}${passed} passed${RESET}\n` : `${passed} passed\n`;
  } else {
    yield color ? `${passed} passed, ${RED}${failed} failed${RESET}\n` : `${passed} passed, ${failed} failed\n`;
  }
}
