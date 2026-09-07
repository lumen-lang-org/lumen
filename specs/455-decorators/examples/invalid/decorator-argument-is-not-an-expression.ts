// A decorator argument is metadata, so it must be a literal (or a bare
// identifier, deliberately accepted -- src/lumen_ast.zig's `.ident` variant
// supports `@Guard(fnName, ...)`-style name-application decorators) and
// never a general expression: nothing has been evaluated when the compiler
// reads it. `1 + 2` is neither.
import { entity } from "./tools/entity.ts";

@entity(1 + 2)
class Agent {
  id: string;
}

function main(): void {
  console.log("unreachable");
}

main();
