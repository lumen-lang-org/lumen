import { Point, origin } from "./point.ts";

export function firstX(): int {
  let p: Point = origin();
  return p.x;
}
