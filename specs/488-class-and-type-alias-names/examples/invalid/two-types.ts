// Two modules declaring the same TYPE name is still a real conflict.
import { gateA } from "./shape-a.ts";
import { gateB } from "./shape-b.ts";

function main(): void {
  console.log(`${gateA().limit + gateB().other}`);
}
main();
