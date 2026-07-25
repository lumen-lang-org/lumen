// A decorator that refuses the description it was given. It exits non-zero, and
// its stderr is the compile error, at the decorator's line.
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

export function boom(d: Description): string {
  if (d.fields.length < 3) {
    throw new Error("@boom wants at least three fields, and " + d.name + " has " + `${d.fields.length}`);
  }
  return d.name;
}
