import { Counter, Named, Colour, greet } from "./lib/counter.ts";

function main(): void {
  let c = new Counter(10);
  console.log(greet("world"));
  console.log("bumped " + c.bump(5).toString());
  let n: Named = { name: "joule" };
  console.log("named " + n.name);
  if (Colour.Green != Colour.Red) { console.log("enum members differ"); }
}

main();
