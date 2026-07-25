// A decorator written before methods were described: its `Description` names
// the keys spec 455 had and not one more. It is handed exactly those, so the
// description growing a `methods` array is invisible to it (spec 459).

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

export function caption(d: Description): string {
  return d.args[0] + "/" + d.name + "/" + `${d.fields.length}`;
}
