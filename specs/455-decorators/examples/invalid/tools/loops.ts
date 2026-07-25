// A decorator module that imports the file it decorates. Left alone this is an
// infinite regress: the file cannot be compiled until the decorator has run,
// and the decorator cannot be compiled until the file has.
import { Marker } from "../decorator-cycle.ts";

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

export function loops(d: Description): string {
  let m: Marker = { seen: d.name };
  return m.seen;
}
