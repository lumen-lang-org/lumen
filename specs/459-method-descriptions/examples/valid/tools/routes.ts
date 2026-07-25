// A class decorator that reads the methods of the class it is written on
// (spec 459): a method decorator is data for `@routes`, resolved by nobody,
// exactly as a field decorator already was.

import { Route, Routes } from "./route-shape.ts";

export type DecoratorUse = {
  name: string,
  args: string[],
};

export type ParamDescription = {
  name: string,
  type: string,
  decorators: DecoratorUse[],
};

export type FieldDescription = {
  name: string,
  type: string,
  decorators: DecoratorUse[],
};

// A method is described exactly as a decorated function is, so this is the
// function description's own shape with the declaration's decorators beside it.
export type MethodDescription = {
  name: string,
  returns: string,
  params: ParamDescription[],
  decorators: DecoratorUse[],
};

export type Description = {
  protocol: int,
  kind: string,
  name: string,
  args: string[],
  file: string,
  line: int,
  fields: FieldDescription[],
  methods: MethodDescription[],
};

// The HTTP verb a method was tagged with, or "none" for a method nobody tagged.
export function verbOf(m: MethodDescription): string {
  if (m.decorators.length > 0) {
    return m.decorators[0].name;
  }
  return "none";
}

export function pathOf(m: MethodDescription): string {
  if (m.decorators.length > 0 && m.decorators[0].args.length > 0) {
    return m.decorators[0].args[0];
  }
  return "";
}

// Parameters as written, with each parameter's own decorator named: a route
// generator needs to know which parameter carries the id.
export function paramsOf(m: MethodDescription): string {
  let out = "";
  let i: int = 0;
  while (i < m.params.length) {
    if (i > 0) { out = out + ","; }
    out = out + m.params[i].name + ":" + m.params[i].type;
    if (m.params[i].decorators.length > 0) {
      out = out + "@" + m.params[i].decorators[0].name + "(" + m.params[i].decorators[0].args[0] + ")";
    }
    i = i + 1;
  }
  return out;
}

export function routes(d: Description): Routes {
  let rs: Route[] = [];
  let i: int = 0;
  while (i < d.methods.length) {
    let r: Route = {
      verb: verbOf(d.methods[i]),
      path: pathOf(d.methods[i]),
      handler: d.methods[i].name,
      params: paramsOf(d.methods[i]),
      returns: d.methods[i].returns,
    };
    rs.push(r);
    i = i + 1;
  }
  let all: Routes = { base: d.args[0], routes: rs, count: rs.length };
  return all;
}
