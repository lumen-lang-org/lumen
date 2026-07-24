import { total as innerTotal, half } from "./wrapper-lib.ts";
import { twice } from "./wrapper-mid.ts";

export function total(a: int, b: int): int {
  return innerTotal(a, b) + 100;
}

console.log(`${total(1, 2)},${half(8)},${twice(5)}`);
