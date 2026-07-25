// Two decorators on one declaration both run, each producing its own constant,
// and neither sees the other's output: they receive declarations, not programs.
import { tag, caption } from "./tools/tag.ts";
import { Shape } from "./tools/shape.ts";

@tag("agents")
@caption("people")
class Agent {
  id: string;
  agentName: string;
}

function main(): void {
  let s: Shape = tagAgent;
  console.log(s.table + " " + captionAgent);
}

main();
