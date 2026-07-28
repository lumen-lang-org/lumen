// Spec 477: a decorated class handed to a server whole.
//
// The call site names no route table, invents no handler-name prefix, and
// writes no binding map — `mount` is generic and says all of it once, using
// `Class.nameOf`, `Class.decorator` and `Class.invoke`.

import { routes } from "./tools/route.ts";
import { Route } from "./tools/route.ts";

type Request = {
  path: string,
  params: Map<string, string>,
};

type Reply = {
  status: int,
  body: string,
};

// --- the framework ----------------------------------------------------------

type Mount = {
  controller: string,
  routes: Route[],
  call: (handler: string, req: Request) => Reply,
};

// Said once, for every controller there will ever be. The `try` is here, in the
// framework: `Class.invoke` lowers to direct method calls, so a throwing
// handler comes back as a throw and is caught — no call site has to remember.
function mount<T>(c: T): Mount {
  let m: Mount = {
    controller: Class.nameOf(c),
    routes: Class.decorator(c, "routes"),
    call: (handler: string, req: Request) => {
      try { return Class.invoke(c, handler, req); }
      catch (e) {
        let bad: Reply = { status: 400, body: "the request could not be handled: " + e.message };
        return bad;
      }
    },
  };
  return m;
}

function segments(path: string): string[] {
  let out: string[] = [];
  let parts = path.split("/");
  let i: int = 0;
  while (i < parts.length) {
    if (parts[i] != "") { out.push(parts[i]); }
    i = i + 1;
  }
  return out;
}

function bind(pattern: string, path: string): Map<string, string> {
  let out = new Map<string, string>();
  let ps = segments(pattern);
  let as = segments(path);
  if (ps.length != as.length) { return out; }
  let i: int = 0;
  while (i < ps.length) {
    if (ps[i].startsWith(":")) {
      out.set(ps[i].substring(1, ps[i].length), as[i]);
    } else if (ps[i] != as[i]) {
      return new Map<string, string>();
    }
    i = i + 1;
  }
  out.set("__matched", "yes");
  return out;
}

// Routing is per mount, so two controllers with a `list` never share a keyspace
// and cannot collide. The qualified name exists only to be read.
function serve(mounts: Mount[], method: string, path: string): string {
  let i: int = 0;
  while (i < mounts.length) {
    let j: int = 0;
    while (j < mounts[i].routes.length) {
      let r = mounts[i].routes[j];
      if (r.method == method) {
        let params = bind(r.pattern, path);
        if (params.has("__matched")) {
          let req: Request = { path: path, params: params };
          let out = mounts[i].call(r.handler, req);
          return `${out.status}` + " " + mounts[i].controller + "." + r.handler + " " + out.body;
        }
      }
      j = j + 1;
    }
    i = i + 1;
  }
  return "404 " + path;
}

// --- two controllers, each with a `list` ------------------------------------

@routes("/agents")
class AgentApi {
  label: string;
  constructor(label: string) { this.label = label; }

  @get("/")
  list(req: Request): Reply {
    let r: Reply = { status: 200, body: "agents of " + this.label };
    return r;
  }

  // Throws the way `JSON.parse<T>` throws on a body missing a field: the
  // failure this whole design exists to keep from killing the process.
  @get("/broken")
  broken(req: Request): Reply {
    throw new Error("field \"name\" is missing");
  }

  @get("/:id")
  find(req: Request): Reply {
    let r: Reply = { status: 200, body: "agent " + (req.params.get("id") ?? "?") };
    return r;
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
  let mounts: Mount[] = [mount(new AgentApi("lead")), mount(new ModelApi())];
  console.log(serve(mounts, "GET", "/agents"));
  console.log(serve(mounts, "GET", "/models"));
  console.log(serve(mounts, "GET", "/agents/a1"));
  console.log(serve(mounts, "GET", "/agents/broken"));
  console.log(serve(mounts, "GET", "/nope"));
}

main();
