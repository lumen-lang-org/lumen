// A class decorator reads the class's methods: each method's decorator, its
// parameters (and their decorators) as written, and its return type. `@get`,
// `@post` and `@param` are resolved by nobody — they are data for `@routes`,
// the same standing a field decorator already has.
import { routes } from "./tools/routes.ts";
import { Routes } from "./tools/route-shape.ts";

@routes("/agents")
class AgentApi {
  base: string;

  @get("/:id")
  find(@param("the id") id: string): string {
    return this.base + id;
  }

  @post("/")
  create(name: string, count: int): int {
    return count;
  }

  // A method nobody decorated is described all the same.
  ping(): string {
    return "pong";
  }
}

function main(): void {
  let r: Routes = routesAgentApi;
  console.log(r.base + " " + `${r.count}`);
  let i: int = 0;
  while (i < r.count) {
    console.log(r.routes[i].verb + " " + r.routes[i].path + " " + r.routes[i].handler + "(" + r.routes[i].params + ") -> " + r.routes[i].returns);
    i = i + 1;
  }
  let a = new AgentApi();
  a.base = "/agents/";
  console.log(a.find("7") + " " + a.ping());
}

main();
