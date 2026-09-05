// Shared test plumbing: a scratch directory per test and a child `node`
// that loads the package's globals, for behaviour only observable from a
// separate process (stdio, exit status, the globals install itself).
import { mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, delimiter } from "node:path";
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

/** The first directory on `env.PATH` holding an executable `name`, or null. */
export function findOnPath(name, env = process.env) {
  for (const dir of (env.PATH ?? "").split(delimiter)) {
    if (dir.length > 0 && existsSync(join(dir, name))) return dir;
  }
  return null;
}

/** The environment a native compile runs in. `lumen compile` invokes `zig`
 *  from PATH (src/lumen.zig), so the shell running this suite must carry it,
 *  as it must for `zig build`. A shell that does not — a runner that forgot
 *  `export PATH=$HOME/.zig:$PATH` — gets the toolchain tools/node-target-env.sh
 *  installs, at `$ZIG_DIR` (default `$HOME/.zig`), put on the child's PATH;
 *  `zigDir` is null when neither place has one, and the suite says so once
 *  rather than failing every native compile with the same bare error. */
export function toolchainEnv(extra = {}) {
  const env = childEnv(extra);
  let zigDir = findOnPath("zig", env);
  if (!zigDir) {
    const installed = process.env.ZIG_DIR ?? join(homedir(), ".zig");
    if (existsSync(join(installed, "zig"))) {
      zigDir = installed;
      env.PATH = `${installed}${delimiter}${env.PATH ?? ""}`;
    }
  }
  return { env, zigDir };
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
