// A decorator argument is metadata, so it is a literal and never an
// expression: nothing has been evaluated when the compiler reads it.
let name = "agents";

@entity(name)
class Agent {
  id: string;
}

function main(): void {
  console.log("unreachable");
}

main();
