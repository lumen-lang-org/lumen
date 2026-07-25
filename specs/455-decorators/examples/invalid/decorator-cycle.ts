import { loops } from "./tools/loops.ts";

export type Marker = {
  seen: string,
};

@loops("agents")
class Agent {
  id: string;
}

function main(): void {
  console.log(loopsAgent);
}

main();
