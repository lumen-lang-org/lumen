// Two modules export LIMIT; a third names both. Each keeps its own value.
import { oneLimit } from "./one.ts";
import { twoLimit } from "./two.ts";
import { privateLimit } from "./private.ts";

function main(): void {
  console.log(`${oneLimit()}`);
  console.log(`${twoLimit()}`);
  console.log(`${privateLimit()}`);
  // The importer may also name an exported symbol directly; it resolves
  // through the exporting module's table, not by spelling.
  console.log(`${oneLimit() + twoLimit()}`);
}
main();
