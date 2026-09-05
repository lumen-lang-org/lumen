// `assert.*` (spec 040): a failed assertion ends the program, uncatchably,
// the way the native runtime's panic does — the message on stderr, then
// SIGABRT. Nothing a Lumen `try` can observe.
import { toBuffer } from "./lang.mjs";
import nfs from "node:fs";
import { kill, exit, pid } from "node:process";

function crash(message) {
  try { nfs.writeSync(2, toBuffer(`panic: ${message}\n`)); } catch {}
  try { kill(pid, "SIGABRT"); } catch {}
  exit(134);
}

export function ok(cond) {
  if (!cond) crash("AssertionError: assert.ok failed");
}

export function equal(a, b) {
  if (a === b) return;
  if (typeof a === "string" && typeof b === "string") crash(`AssertionError: "${a}" != "${b}"`);
  crash(`AssertionError: ${a} != ${b}`);
}
