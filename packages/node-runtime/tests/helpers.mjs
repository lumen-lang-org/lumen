// Shared test plumbing: a scratch directory per test and a child `node`
// that loads the package's globals, for behaviour only observable from a
// separate process (stdio, exit status, the globals install itself).
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const GLOBALS = fileURLToPath(new URL("../globals.mjs", import.meta.url));
export const INDEX = fileURLToPath(new URL("../index.mjs", import.meta.url));

export function scratch(fn) {
  const dir = mkdtempSync(join(tmpdir(), "lumen-node-"));
  const cleanup = () => rmSync(dir, { recursive: true, force: true });
  let result;
  try {
    result = fn(dir);
  } catch (e) {
    cleanup();
    throw e;
  }
  if (result && typeof result.then === "function") return result.finally(cleanup);
  cleanup();
  return result;
}

/** The environment a spawned program sees: ours, minus the marker the outer
 *  `node --test` run sets for its own children (a program under test must
 *  behave as it would under a plain `node`). */
export function childEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  delete env.NODE_TEST_CONTEXT;
  return env;
}

/** Runs `source` (a .ts program) under `node --import globals.mjs`. */
export function runProgram(source, { args = [], input = "", env = {}, cwd, flags = [] } = {}) {
  return scratch((dir) => {
    const file = join(dir, "prog.ts");
    writeFileSync(file, source);
    const r = spawnSync(process.execPath, ["--no-warnings", ...flags, "--import", GLOBALS, file, ...args], {
      cwd: cwd ?? dir,
      input,
      encoding: "latin1",
      env: childEnv(env),
      timeout: 20000,
    });
    return { stdout: r.stdout ?? "", stderr: r.stderr ?? "", status: r.status, signal: r.signal };
  });
}
