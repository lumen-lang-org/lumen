// Spec 478: the controllers go in as themselves.
//
// `serveAll` takes `Mount[]`. The array below holds two different classes, so
// it is not a `Mount[]` and is not any array — but `mount<T>` is the one
// generic function in this program that makes a `Mount`, so each element goes
// through it. The word `mount` is gone from the call site; the erasure it named
// still happens.
//
// The second list proves the old form still compiles: a `Mount` written by hand
// is still a `Mount`.

import { routes } from "./tools/route.ts";
import { Route } from "./tools/route.ts";

type Request = {
  path: string,
};

type Reply = {
  status: int,
  body: string,
};

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

function serveAll(mounts: Mount[], path: string): string {
  let i: int = 0;
  while (i < mounts.length) {
    let j: int = 0;
    while (j < mounts[i].routes.length) {
      if (mounts[i].routes[j].pattern == path) {
        let out = mounts[i].call(mounts[i].routes[j].handler, { path: path });
        return `${out.status}` + " " + mounts[i].controller + "." + mounts[i].routes[j].handler + " " + out.body;
      }
      j = j + 1;
    }
    i = i + 1;
  }
  return "404 " + path;
}

@routes("/agents")
class AgentApi {
  label: string;
  constructor(label: string) { this.label = label; }

  @get("/")
  list(req: Request): Reply {
    let r: Reply = { status: 200, body: "agents of " + this.label };
    return r;
  }

  @get("/broken")
  broken(req: Request): Reply {
    throw new Error("field \"name\" is missing");
  }
}

@routes("/models")
class ModelApi {
  @get("/")
  list(req: Request): Reply {
    let r: Reply = { status: 200, body: "models" };
    return r;
  }
}

function main(): void {
  // The new form: the instances, as themselves.
  let mounts: Mount[] = [new AgentApi("lead"), new ModelApi()];
  console.log(serveAll(mounts, "/agents"));
  console.log(serveAll(mounts, "/models"));
  console.log(serveAll(mounts, "/agents/broken"));

  // The old form, unchanged: a `Mount` built by hand is still accepted.
  let byHand: Mount[] = [mount(new AgentApi("second"))];
  console.log(serveAll(byHand, "/agents"));
}

main();
