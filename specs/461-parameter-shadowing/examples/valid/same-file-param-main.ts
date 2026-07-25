// The collision inside one file: a function, a class and a record type are
// all shadowed by parameters that keep their spelling in the source.
type row = { id: int };

function value(n: int): int { return n * 2; }

class Handler {
  n: int;
  constructor(value: int) { this.n = value; }
  scale(value: int, row: int): int { return this.n * value + row; }
}

function report(value: int, row: row): string {
  return `${value}:${row.id}`;
}

function main(): void {
  let r: row = { id: 7 };
  console.log(report(value(3), r));
  let h = new Handler(4);
  console.log(`${h.scale(5, 1)}`);
}
main();
