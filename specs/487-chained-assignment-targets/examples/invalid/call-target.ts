class Leaf { v: int; constructor(v: int) { this.v = v; } }

function make(): Leaf { return new Leaf(1); }

function main(): void {
  make() = 5;
}

main();
