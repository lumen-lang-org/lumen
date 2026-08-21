// A method named like an imported function, calling that function by its bare
// name from a sibling method.
import { run, twice } from "./lib.ts";

class Runner {
  runAgain(): int { return run(); }
  run(): int { return 0; }
  both(): int { return run() + twice(); }
  viaValue(): int {
    let f: () => int = run;
    return f();
  }
  viaArrow(): int {
    let nums: int[] = [1, 2];
    return nums.map((n: int) => n * run()).length;
  }
}

function main(): void {
  let r = new Runner();
  console.log(`${r.runAgain()}`);
  console.log(`${r.run()}`);
  console.log(`${r.both()}`);
  console.log(`${r.viaValue()}`);
  console.log(`${r.viaArrow()}`);
  console.log(`${run()}`);
}
main();
