// The type a `@routes` decorator returns, and the decorator itself. A miniature
// of std-contrib's `packages/rest`: enough of a route table to show that a
// decorated class can be handed to a server whole.

export type Route = {
  method: string,
  pattern: string,
  handler: string,
};

export type DecoratorUse = {
  name: string,
  args: string[],
};

export type MethodDescription = {
  name: string,
  decorators: DecoratorUse[],
};

export type Description = {
  protocol: int,
  kind: string,
  name: string,
  args: string[],
  file: string,
  line: int,
  methods: MethodDescription[],
};

function argOf(m: MethodDescription, name: string): string {
  let i: int = 0;
  while (i < m.decorators.length) {
    if (m.decorators[i].name == name && m.decorators[i].args.length > 0) {
      return m.decorators[i].args[0];
    }
    i = i + 1;
  }
  return "";
}

function has(m: MethodDescription, name: string): bool {
  let i: int = 0;
  while (i < m.decorators.length) {
    if (m.decorators[i].name == name) { return true; }
    i = i + 1;
  }
  return false;
}

function join(prefix: string, tail: string): string {
  if (tail == "" || tail == "/") { return prefix; }
  return prefix + tail;
}

export function routes(d: Description): Route[] {
  let out: Route[] = [];
  let i: int = 0;
  while (i < d.methods.length) {
    let m = d.methods[i];
    if (has(m, "get")) {
      let r: Route = { method: "GET", pattern: join(d.args[0], argOf(m, "get")), handler: m.name };
      out.push(r);
    }
    i = i + 1;
  }
  return out;
}
