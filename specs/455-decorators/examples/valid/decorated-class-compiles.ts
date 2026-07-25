// Slice 1: a decorator is syntax the compiler records and every later phase
// ignores. A decorated class compiles and runs exactly as an undecorated one.
@entity("agents")
class Agent {
  @id @column("id", "text")
  id: string;

  @column("agent_name", "text")
  agentName: string;
}

function main(): void {
  let a = new Agent();
  a.id = "a1";
  a.agentName = "researcher";
  console.log(a.id + ":" + a.agentName);
}

main();
