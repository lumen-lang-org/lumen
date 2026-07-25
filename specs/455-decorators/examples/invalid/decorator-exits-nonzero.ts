import { boom } from "./tools/boom.ts";

@boom("agents")
class Agent {
  id: string;
}

function main(): void {
  console.log(boomAgent);
}

main();
