// A minimal, correctly-shaped decorator (spec 455) -- exists only so
// decorator-argument-is-not-an-expression.ts's own import resolves and its
// signature checks out, letting the fixture actually reach the
// E_DECORATOR_ARG check it's named for, instead of failing earlier on an
// unrelated "not imported" or "wrong signature" error.
export type Description = {
  protocol: int,
  kind: string,
  name: string,
  args: string[],
  file: string,
  line: int,
  fields: string[],
};

export function entity(d: Description): string {
  return d.name;
}
