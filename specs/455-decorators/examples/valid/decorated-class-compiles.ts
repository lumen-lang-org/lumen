// A decorator resolves through an ordinary import, runs while this file is
// compiled, and leaves a constant named for itself and the declaration it was
// written on. `@column` is a field decorator: it is data for `@tag` to read,
// and is resolved by nobody.
import { tag } from "./tools/tag.ts";
import { Shape } from "./tools/shape.ts";

@tag("agents")
class Agent {
  @column("id")
  id: string;

  @column("agent_name")
  agentName: string;
}

// The decorator's module declares a `columnOf` too. It is not this one: an
// import that named a decorator contributes the binding and nothing else.
function columnOf(i: int): string {
  return tagAgent.columns[i].column;
}

function main(): void {
  let a = new Agent();
  a.id = "a1";
  a.agentName = "researcher";
  let s: Shape = tagAgent;
  console.log(a.id + ":" + a.agentName + " " + s.table + " " + columnOf(1) + " " + `${s.count}`);
}

main();
