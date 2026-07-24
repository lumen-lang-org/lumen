import { greet as hello } from "./greet-lib.ts";

type Box = { hello: string, n: int };

function make(): Box {
  return { hello: "field", n: 1 };
}

let b: Box = make();
console.log(`${hello("a")}|${b.hello}|${b.n}`);
