class Leaf {
  v: int;
  constructor(v: int) { this.v = v; }
  get(): int { return this.v; }
}

function main(): void {
  let leaf: Leaf = new Leaf(1);
  leaf.get() = 5;
}

main();
