// A class in the list that carries no `@routes`. There is no route table for
// it, so it cannot be served — and that is a compile error naming the class, at
// the call that named it, not an empty route set discovered at run time.

import { routes } from "./tools/route.ts";
import { Route } from "./tools/route.ts";

type Request = { path: string };
type Reply = { status: int, body: string };

type Mount = {
  controller: string,
  routes: Route[],
  call: (handler: string, req: Request) => Reply,
};

function mount<T>(c: T): Mount {
  let m: Mount = {
    controller: Class.nameOf(c),
    routes: Class.decorator(c, "routes"),
    call: (handler: string, req: Request) => {
      try { return Class.invoke(c, handler, req); }
      catch (e) {
        let bad: Reply = { status: 400, body: e.message };
        return bad;
      }
    },
  };
  return m;
}

@routes("/agents")
class AgentApi {
  @get("/")
  list(req: Request): Reply {
    let r: Reply = { status: 200, body: "agents" };
    return r;
  }
}

class NotAController {
  @get("/")
  list(req: Request): Reply {
    let r: Reply = { status: 200, body: "nothing" };
    return r;
  }
}

function main(): void {
  let mounts: Mount[] = [new AgentApi(), new NotAController()];
  console.log(`${mounts.length}`);
}

main();
