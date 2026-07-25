// An arrow's parameter is in the same generated namespace as a function's.
function label(s: string): string { return `[${s}]`; }

function main(): void {
  let names = ["a", "b"];
  let marked = names.map((label: string) => label + "!");
  console.log(marked.join(","));
  console.log(label("z"));
}
main();
