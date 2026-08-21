// The colliding method is declared on the ancestor; the derived struct carries
// it, so the derived class's own body has to route around it too.
import { run } from "./lib.ts";

function local(): int { return 7; }

class Base {
  run(): int { return 100; }
  local(): int { return 0; }
}

class Child extends Base {
  viaCall(): int { return run(); }
  viaLocal(): int { return local(); }
}

function main(): void {
  let c = new Child();
  console.log(`${c.run()}`);
  console.log(`${c.viaCall()}`);
  console.log(`${c.viaLocal()}`);
}
main();
