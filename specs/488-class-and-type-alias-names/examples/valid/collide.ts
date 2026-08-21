// A class here, an unrelated type alias of the same name there.
import { ApprovalGate } from "./gate.ts";
import { ApprovalGate as GateShape, defaultGate } from "./shape.ts";
import { nodeValue } from "./kinds.ts";
import { nodeWeight } from "./kinds_type.ts";

function main(): void {
  let g = new ApprovalGate("full-auto");
  console.log(g.describe());
  // The renamed type is still importable under its source name, and still
  // usable in the importer's own annotation.
  let s: GateShape = defaultGate();
  console.log(`${s.limit}`);
  console.log(`${nodeValue()}`);
  console.log(`${nodeWeight()}`);
}
main();
