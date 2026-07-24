import { origin } from "./point.ts";
import { sum } from "./sub/via.ts";

let p = origin();
console.log(`${p.x + p.y},${sum()}`);
