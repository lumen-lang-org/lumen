// A class with no methods still describes a methods array: the key is always
// there, empty, so a decorator reads it without asking whether it exists. The
// decorator's `Description` declares `methods`, and a missing key would not
// parse -- so a count of 0 here is the empty array, not a silent absence.
import { routes } from "./tools/routes.ts";
import { Routes } from "./tools/route-shape.ts";

@routes("/plain")
class Plain {
  id: string;
  size: int;
}

function main(): void {
  let r: Routes = routesPlain;
  console.log(r.base + " " + `${r.count}`);
}

main();
