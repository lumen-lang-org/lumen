type Outcome = { code: int };

export function fromB(): int {
  let r: Outcome = { code: 2 };
  return r.code;
}
