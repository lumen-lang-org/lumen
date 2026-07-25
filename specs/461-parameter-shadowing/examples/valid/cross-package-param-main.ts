// The reproduction: two packages that never heard of each other, one taking a
// `json` parameter and one exporting a `json` function, in one program.
import { json, ok } from "./replies.ts";
import { persist } from "./store.ts";

function main(): void {
  console.log(persist("agents", "{\"id\":1}"));
  console.log(json(201, "created"));
  console.log(ok("fine"));
}
main();
