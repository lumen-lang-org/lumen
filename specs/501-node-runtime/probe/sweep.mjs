import { stripTypeScriptTypes } from "node:module";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { globSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
const S = process.env.S ?? join(tmpdir(), "lumen-node-probe");
const files = globSync("src/**/*.ts");
let ok = 0; const bad = [];
mkdirSync(S + "/stripped", { recursive: true });
for (const f of files) {
  const src = readFileSync(f, "utf8");
  let out;
  try { out = stripTypeScriptTypes(src, { mode: "strip" }); } catch (e) { bad.push([f, "strip: " + e.message.split("\n")[0]]); continue; }
  const tmp = S + "/stripped/" + f.replace(/\//g, "__") + ".mjs";
  writeFileSync(tmp, out);
  try { execFileSync(process.execPath, ["--check", tmp], { stdio: ["ignore", "ignore", "pipe"] }); ok++; }
  catch (e) { const m = String(e.stderr).split("\n").find(l => /Error/.test(l)) || "?"; bad.push([f, m]); }
}
console.log("parse ok=" + ok + " bad=" + bad.length);
for (const [f, m] of bad) console.log("  " + f + ": " + m.slice(0, 160));
