// A decorator on a function receives its parameters, their own decorators, and
// its return type — as written, since the file has not been checked when the
// decorator runs.
import { signatureOf } from "./tools/sig.ts";
import { Signature } from "./tools/signature.ts";

@signatureOf("search")
function search(@describe("what to look for") q: string, limit: int): string[] {
  let out: string[] = [];
  let i: int = 0;
  while (i < limit) {
    out.push(q);
    i = i + 1;
  }
  return out;
}

function main(): void {
  let s: Signature = signatureOfSearch;
  console.log(s.name + " " + s.params + " -> " + s.returns + " " + search("ab", 3).length);
}

main();
