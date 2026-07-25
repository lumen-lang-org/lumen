// Two decorators over a class description (spec 455).

import { Column, Shape } from "./shape.ts";

// The description the compiler passes in. Declared here until the compiler
// provides the type; the generated entry point parses into it, so every key the
// compiler writes is named exactly once.
export type DecoratorUse = {
  name: string,
  args: string[],
};

export type FieldDescription = {
  name: string,
  type: string,
  decorators: DecoratorUse[],
};

export type ParamDescription = {
  name: string,
  type: string,
  decorators: DecoratorUse[],
};

// A class description carries its methods too (spec 459). `JSON.parse` accepts
// only the keys the type declares, so a description type names every key the
// compiler writes, including the ones this decorator has no use for.
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

// A helper the decorated program also declares, under the same name: an import
// that named a decorator contributes the binding and nothing else, so these two
// never meet.
export function columnOf(f: FieldDescription): string {
  let i: int = 0;
  while (i < f.decorators.length) {
    if (f.decorators[i].name == "column" && f.decorators[i].args.length > 0) {
      return f.decorators[i].args[0];
    }
    i = i + 1;
  }
  return f.name;
}

export function tag(d: Description): Shape {
  let cols: Column[] = [];
  let i: int = 0;
  while (i < d.fields.length) {
    let c: Column = { field: d.fields[i].name, column: columnOf(d.fields[i]) };
    cols.push(c);
    i = i + 1;
  }
  let s: Shape = { table: d.args[0], columns: cols, count: cols.length };
  return s;
}

// A decorator returns whatever JSON can carry, including a scalar.
export function caption(d: Description): string {
  return d.args[0] + "/" + d.name + "/" + `${d.fields.length}`;
}
