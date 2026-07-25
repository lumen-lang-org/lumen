// A decorator is an imported function. A name that is not imported names
// nothing, and says so at the decorator's own line.
@entity("agents")
class Agent {
  id: string;
}

function main(): void {
  let a = new Agent();
  a.id = "a1";
  console.log(a.id);
}

main();
