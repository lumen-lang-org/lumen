import { halfWritten } from "./tools/uncompilable.ts";

@halfWritten("agents")
class Agent {
  id: string;
}

function main(): void {
  console.log(halfWrittenAgent);
}

main();
