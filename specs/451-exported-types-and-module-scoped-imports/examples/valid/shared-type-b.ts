import { Point, origin } from "./point.ts";

export function secondY(): int {
  let p: Point = origin();
  return p.y + 1;
}
