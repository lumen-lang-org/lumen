// A decorator module with an error of its own. It is the user's code, with its
// own file and lines, so its diagnostic is the message — reported under the
// decorator that pulled it in, not as an error of the file being compiled.
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

export function halfWritten(d: Description): string {
  return d.tableName;
}
