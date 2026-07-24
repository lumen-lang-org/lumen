type Outcome = { ok: bool };

export function fromA(): int {
  let r: Outcome = { ok: true };
  return r.ok ? 1 : 0;
}
