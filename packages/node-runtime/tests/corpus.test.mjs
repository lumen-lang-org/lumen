// Spec 503 SC-002: every program in corpus.txt prints under
// `node --import globals.mjs` exactly what the native binary prints. The
// native side is `zig-out/bin/lumen run` (build it with `zig build`); the
// programs are hand-written .ts modules, so they run with the interim
// `LUMEN_STRINGS=utf16` boundary (FR-002).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { basename, join } from "node:path";
import { fileURLToPath } from "node:url";
import { GLOBALS, childEnv } from "./helpers.mjs";

const ROOT = fileURLToPath(new URL("../../../", import.meta.url));
const LUMEN = join(ROOT, "zig-out/bin/lumen");
const CORPUS = fileURLToPath(new URL("./corpus.txt", import.meta.url));

const programs = readFileSync(CORPUS, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter((l) => l.length > 0 && !l.startsWith("#"));

function native(rel) {
  const r = spawnSync(LUMEN, ["run", `specs/${rel}`], { cwd: ROOT, encoding: "latin1", stdio: ["ignore", "pipe", "pipe"], timeout: 120000, maxBuffer: 64 * 1024 * 1024 });
  // `lumen run` leaves the executable beside the working directory, as the
  // conformance runner's removeGenerated documents.
  const stem = basename(rel, ".ts");
  for (const junk of [join(ROOT, stem), join(ROOT, `${stem}.zig`)]) { try { unlinkSync(junk); } catch {} }
  return r;
}

function node(rel) {
  return spawnSync(process.execPath, ["--no-warnings", "--import", GLOBALS, `specs/${rel}`], {
    cwd: ROOT, encoding: "latin1", stdio: ["ignore", "pipe", "pipe"], timeout: 30000, maxBuffer: 64 * 1024 * 1024,
    env: childEnv({ LUMEN_STRINGS: "utf16" }),
  });
}

test("corpus.txt names programs that exist and the native compiler is built", () => {
  assert.ok(programs.length > 0, "corpus.txt is empty");
  assert.ok(existsSync(LUMEN), `${LUMEN} is missing: run \`zig build\` first`);
  for (const rel of programs) assert.ok(existsSync(join(ROOT, "specs", rel)), `${rel} is not in specs/`);
});

for (const rel of programs) {
  test(`corpus: ${rel}`, () => {
    const n = native(rel);
    assert.equal(n.status, 0, `native run failed:\n${n.stderr}`);
    const j = node(rel);
    assert.equal(j.status, 0, `node run failed:\n${j.stderr}`);
    assert.equal(j.stdout, n.stdout);
  });
}
