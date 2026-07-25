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

export type Description = {
  protocol: int,
  kind: string,
  name: string,
  args: string[],
  file: string,
  line: int,
  fields: FieldDescription[],
};

export function boom(d: Description): string {
  if (d.fields.length < 3) {
    throw new Error("@boom wants at least three fields, and " + d.name + " has " + `${d.fields.length}`);
  }
  return d.name;
}
