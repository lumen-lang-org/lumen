import { test } from "node:test";
import assert from "node:assert/strict";
import { runProgram } from "./helpers.mjs";

test("question(prompt) writes the prompt and returns the line without its terminator; \"\" at EOF (spec 058)", () => {
  const r = runProgram('const a = readline.question("name? "); const b = readline.question("more? "); const c = readline.question("eof? "); console.log(JSON.stringify([a, b, c]));', { input: "Ada\r\n\nrest" });
  assert.equal(r.status, 0);
  assert.equal(r.stdout, 'name? more? eof? ["Ada","","rest"]\n');
  const e = runProgram('console.log(JSON.stringify(readline.question("> ")));', { input: "" });
  assert.equal(e.stdout, '> ""\n');
});
