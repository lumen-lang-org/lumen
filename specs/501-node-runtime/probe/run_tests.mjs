import { globSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
const PRELUDE = join(import.meta.dirname, "lumen_node_prelude.mjs");
const files = globSync("src/**/*.test.ts").sort();
let summary = { files: files.length, clean: 0, partial: 0, importError: 0, pass: 0, fail: 0 };
const errs = {}; const reasons = {};
for (const f of files) {
  let out;
  try { out = execFileSync(process.execPath, ["--no-warnings", "--import", PRELUDE, "--input-type=module", "-e",
    `await import(${JSON.stringify(process.cwd() + "/" + f)}).then(()=>{},e=>{globalThis.__t.importError=(e.stack||String(e)).split("\\n").slice(0,2).join(" | ")}); console.log(JSON.stringify(globalThis.__t));`], { encoding: "utf8", timeout: 20000, stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) { errs[f] = "process died: " + String(e.stderr || e.message).split("\n").filter(Boolean).slice(-1)[0]; summary.importError++; continue; }
  const line = out.trim().split("\n").pop(); let t; try { t = JSON.parse(line); } catch { errs[f] = "no summary: " + out.slice(-120); summary.importError++; continue; }
  summary.pass += t.pass; summary.fail += t.fail;
  if (t.importError) { summary.importError++; errs[f] = t.importError; }
  else if (t.fail === 0) summary.clean++; else { summary.partial++; reasons[f] = t.failures.slice(0, 3); }
}
console.log(JSON.stringify(summary));
console.log("--- import errors (first line each)");
for (const [f, m] of Object.entries(errs)) console.log(f + ": " + m.slice(0, 170));
console.log("--- failing test samples");
for (const [f, m] of Object.entries(reasons)) console.log(f + ": " + m.join(" || ").slice(0, 220));
