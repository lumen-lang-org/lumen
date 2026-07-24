import { origin } from "../point.ts";

export function sum(): int {
  let p = origin();
  return p.x + p.y;
}
