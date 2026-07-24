import { greet as hello } from "./greet-lib.ts";
import { loud } from "./greet-mid.ts";

console.log(hello("a") + " " + loud("b"));
