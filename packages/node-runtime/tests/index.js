// `node --test tests/` on Node 22 resolves the directory as a module and
// runs this file as the one test file; importing every `*.test.mjs`
// registers their tests here. `node --test tests/*.test.mjs` runs them as
// separate processes instead; both are supported.
import { readdirSync } from "node:fs";

const here = new URL("./", import.meta.url);
for (const name of readdirSync(here).filter((n) => n.endsWith(".test.mjs")).sort()) {
  await import(new URL(name, here));
}
