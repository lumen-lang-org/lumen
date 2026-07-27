// Spec 473's case, kept alongside so a change to one cannot silently break
// the other: a private clash is absorbed the same way.
const LIMIT: int = 3;
export function privateLimit(): int { return LIMIT; }
