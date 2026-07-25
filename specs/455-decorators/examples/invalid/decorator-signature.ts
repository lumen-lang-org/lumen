import { widen } from "./tools/wrong-signature.ts";

@widen("agents")
class Agent {
  id: string;
}

function main(): void {
  console.log("unreachable");
}

main();
