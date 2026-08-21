class Leaf { v: int; constructor(v: int) { this.v = v; } }

function main(): void {
  let grid: Leaf[][] = [[new Leaf(1)]];
  grid[0][0] = new Leaf(2);
}

main();
