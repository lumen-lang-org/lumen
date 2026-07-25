// The class has methods; the decorator has never heard of them. A decorator is
// handed the keys its own `Description` declares and no others, so a field the
// description gained does not break a decorator written before it existed --
// which is what lets the description grow at all.
import { caption } from "./tools/caption.ts";

@caption("agents")
class AgentApi {
  base: string;

  @get("/:id")
  find(@param("the id") id: string): string {
    return this.base + id;
  }

  ping(): string {
    return "pong";
  }
}

function main(): void {
  console.log(captionAgentApi);
}

main();
