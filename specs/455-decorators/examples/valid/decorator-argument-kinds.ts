// Every literal a decorator argument may be: string, integer, float, boolean.
@table("agents", 2, 0.5, true)
class Agent {
  @column("id")
  id: string;
}

function main(): void {
  let a = new Agent();
  a.id = "a1";
  console.log(a.id);
}

main();
