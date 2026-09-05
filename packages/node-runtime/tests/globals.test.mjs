// FR-004: `globals.mjs` installs, `index.mjs` and the namespace modules do not.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { GLOBALS, INDEX, runProgram, scratch, childEnv } from "./helpers.mjs";

test("importing the index or a namespace module installs nothing on globalThis", () => scratch((dir) => {
  // A file, not `node -e`: the -e mode predefines every builtin module as a global.
  const file = join(dir, "check.mjs");
  writeFileSync(file, `
    import * as L from ${JSON.stringify(INDEX)};
    import * as fs from ${JSON.stringify(INDEX.replace("index.mjs", "lib/fs.mjs"))};
    console.log(JSON.stringify([typeof globalThis.fs, typeof globalThis.time, typeof process.platform, typeof L.fs.readFileSync, typeof fs.readFileSync, globalThis.Buffer === L.Buffer]));`);
  const r = spawnSync(process.execPath, ["--no-warnings", file], { encoding: "utf8", env: childEnv(), timeout: 20000 });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), '["undefined","undefined","string","function","function",false]');
}));

test("node --import globals.mjs puts every namespace in scope and grafts process", () => {
  const r = runProgram(`
    console.log([fs, path, os, crypto, child_process, net, http, zlib, url, time, readline, assert, Buffer, EventEmitter, Worker, test, expect, defer, argsCount, arg].every((x) => x !== undefined));
    console.log(typeof process.platform(), typeof process.pid(), typeof process.cwd(), process.env("HOME") !== undefined, Array.isArray(process.argv()));
    console.log(Buffer.from("abc").at(0), crypto.sha256("").slice(0, 4), typeof __lang.bytes);
  `);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "true\nstring number string true true\n97 e3b0 function\n");
});

test("console.log, console.error and Node's own process.stdout.write keep working after the graft", () => {
  const r = runProgram('console.log("out"); console.error("err"); process.stdout.write("raw\\n"); console.log(typeof process.stdout.isTTY, process.platform == "' + process.platform + '");');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, `out\nraw\n${typeof process.stdout.isTTY} true\n`);
  assert.equal(r.stderr, "err\n");
});

test("text crossing the boundary is bytes, and the console decodes what it prints (505 decision 1)", () => {
  // printf emits the two UTF-8 bytes of "é": the program sees 2 bytes, and
  // printing the string, alone or inside an array, writes those bytes back.
  const prog = String.raw`const s = child_process.spawnSync("printf", ["\\303\\251"]).stdout; console.log(s.length, s.charCodeAt(0)); console.log(s, [s]); console.log(JSON.parse("[\"\\u00e9\"]")[0].length);`;
  const r = runProgram(prog);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "2 195\n\xc3\xa9 [ '\xc3\xa9' ]\n2\n");
});
