// A decorator takes one description and returns a value. This takes two
// numbers, so it is refused against the signature it should have had.
export type Description = {
  protocol: int,
  kind: string,
  name: string,
  args: string[],
  file: string,
  line: int,
  fields: string[],
};

export function widen(a: int, b: int): int {
  return a + b;
}
