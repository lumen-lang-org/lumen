// A static async build past hello-world: async/await, a Promise return, a
// timer, Map, Set, array and string methods, JSON. Built with
// `lumen compile --static async-mixed.ts` and run unchanged on Ubuntu 22.04,
// Rocky Linux 8 and Alpine.
async function work(n: number): Promise<number> {
  return n * 2;
}

async function main(): Promise<void> {
  const doubled = await work(21);
  console.log("doubled=" + doubled.toString());

  const names: string[] = ["ada", "grace", "alan"];
  console.log("upper=" + names.map((n: string) => n.toUpperCase()).join(","));

  const counts = new Map<string, number>();
  for (const n of names) counts.set(n, n.length);
  console.log("ada=" + (counts.get("ada") ?? 0).toString());

  const seen = new Set<number>();
  seen.add(1);
  seen.add(1);
  seen.add(2);
  console.log("set=" + seen.size.toString());

  console.log("json=" + JSON.stringify(names));

  setTimeout(() => { console.log("timer fired"); }, 5);
}

main();
