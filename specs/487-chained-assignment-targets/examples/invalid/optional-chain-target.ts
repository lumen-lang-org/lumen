class Leaf { v: int; constructor(v: int) { this.v = v; } }

function main(): void {
  let leaf: Leaf | null = new Leaf(1);
  leaf?.v = 5;
}

main();
