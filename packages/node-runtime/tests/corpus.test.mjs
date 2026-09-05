// Spec 503 SC-002: every program in corpus.txt prints under
// `node --import globals.mjs` exactly what the native binary prints. The
// programs are the specs' hand-written .ts modules whose literals are ASCII,
// which is text and bytes alike (spec 505 decision 1), run as they are —
// Node strips the types; nothing is emitted.
//
// The native side is what `zig build conformance` pins: a program's
// expectation is the `compile-run` case that names it in its spec's
// conformance/manifest.json, compared the way tools/lumen_conformance.zig
// compares (stdout and stderr concatenated, trailing newlines trimmed, the
// executable run from the repository root). A program no manifest pins is
// compiled and run natively here instead, with `zig-out/bin/lumen` (build
// it with `zig build`), so the check is the same whichever way the
// expectation is obtained. Native compiles are single-threaded and take
// ~20 s each, so the unpinned programs run a few at a time, each compiling
// in its own directory. `lumen compile` runs `zig` from PATH: the suite
// takes the caller's, or the one tools/node-target-env.sh installed
// (helpers.mjs `toolchainEnv`), and names what is missing before any
// compile runs.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync, mkdtempSync, rmSync } from "node:fs";
import { execFile } from "node:child_process";
import { basename, join, resolve, dirname } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { GLOBALS, childEnv, toolchainEnv } from "./helpers.mjs";

const ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const SPECS = join(ROOT, "specs");
const LUMEN = join(ROOT, "zig-out/bin/lumen");
const CORPUS = fileURLToPath(new URL("./corpus.txt", import.meta.url));

const programs = readFileSync(CORPUS, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter((l) => l.length > 0 && !l.startsWith("#"));

const trimTrailingNewlines = (s) => s.replace(/[\r\n]+$/, "");

const toolchain = toolchainEnv();

/** Runs a command to completion; resolves with its status and streams. */
function run(cmd, args, { cwd, timeout, env = childEnv() }) {
  return new Promise((resolveRun) => {
    execFile(cmd, args, { cwd, encoding: "latin1", timeout, maxBuffer: 64 * 1024 * 1024, env }, (err, stdout, stderr) => {
      resolveRun({ status: err ? (typeof err.code === "number" ? err.code : -1) : 0, stdout: stdout ?? "", stderr: stderr ?? "", error: err && typeof err.code !== "number" ? err : null });
    });
  });
}

/** Every spec manifest's compile-run expectation, keyed by the program's
 *  absolute path — what `zig build conformance` holds the native binary to. */
function pinnedExpectations() {
  const pinned = new Map();
  for (const spec of readdirSync(SPECS)) {
    const manifestPath = join(SPECS, spec, "conformance", "manifest.json");
    if (!existsSync(manifestPath)) continue;
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    for (const c of manifest.cases ?? []) {
      if (c.phase !== "compile-run") continue;
      const source = resolve(dirname(manifestPath), c.source);
      if (!pinned.has(source)) pinned.set(source, { id: `${spec}:${c.id}`, stdout: c.expect?.stdout ?? "" });
    }
  }
  return pinned;
}

const pinned = pinnedExpectations();

/** `lumen compile` in a directory of its own (so parallel compiles cannot
 *  share a `<stem>` output), then the executable from the repository root,
 *  as tools/lumen_conformance.zig's checkCompileRun does. */
async function nativeOutput(rel) {
  const source = join(SPECS, rel);
  const stem = basename(rel, ".ts");
  const dir = mkdtempSync(join(tmpdir(), "lumen-corpus-"));
  try {
    const compile = await run(LUMEN, ["compile", source], { cwd: dir, timeout: 180000, env: toolchain.env });
    assert.equal(compile.status, 0, `native compile failed:\n${compile.stderr}`);
    const exe = await run(join(dir, stem), [], { cwd: ROOT, timeout: 60000 });
    assert.equal(exe.status, 0, `native executable failed:\n${exe.stderr}`);
    return trimTrailingNewlines(exe.stdout + exe.stderr);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

async function nodeOutput(rel) {
  const r = await run(process.execPath, ["--no-warnings", "--import", GLOBALS, join(SPECS, rel)], { cwd: ROOT, timeout: 30000 });
  assert.equal(r.status, 0, `node run failed:\n${r.stderr}`);
  return trimTrailingNewlines(r.stdout + r.stderr);
}

const unpinned = programs.filter((rel) => !pinned.has(join(SPECS, rel)));

test("corpus.txt names programs that exist", () => {
  assert.ok(programs.length > 0, "corpus.txt is empty");
  for (const rel of programs) assert.ok(existsSync(join(SPECS, rel)), `${rel} is not in specs/`);
  if (unpinned.length > 0) {
    assert.ok(existsSync(LUMEN), `${LUMEN} is missing and ${unpinned.length} corpus programs have no manifest expectation: run \`zig build\` first`);
    assert.ok(toolchain.zigDir, `zig is neither on PATH nor at $ZIG_DIR/$HOME/.zig, and ${unpinned.length} corpus programs compile natively: run \`sh tools/node-target-env.sh\` and put its PATH line in this shell`);
  }
});

describe("corpus, pinned by a conformance manifest", () => {
  for (const rel of programs) {
    const pin = pinned.get(join(SPECS, rel));
    if (!pin) continue;
    test(`${rel} (${pin.id})`, async () => {
      assert.equal(await nodeOutput(rel), pin.stdout);
    });
  }
});

describe("corpus, compiled natively here", { concurrency: 4 }, () => {
  for (const rel of unpinned) {
    test(rel, async () => {
      const [expected, actual] = await Promise.all([nativeOutput(rel), nodeOutput(rel)]);
      assert.equal(actual, expected);
    });
  }
});
