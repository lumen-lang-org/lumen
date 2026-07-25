// Decorator arguments are literals of every kind: a string, an integer, a
// float, a boolean. They sit on field decorators here — a field decorator is
// data for the enclosing declaration's decorator to read, so nothing resolves
// them, and a description whose arguments are not all strings has no Lumen type
// to be parsed into yet.
import { tag } from "./tools/tag.ts";
import { Shape } from "./tools/shape.ts";

class Meta {
  @size(3) @scale(1.5) @required(true) @named("id")
  id: string;
}

@tag("agents")
class Agent {
  id: string;
}

function main(): void {
  let m = new Meta();
  m.id = "a1";
  let s: Shape = tagAgent;
  console.log(m.id + " " + s.table + " " + `${s.count}`);
}

main();
