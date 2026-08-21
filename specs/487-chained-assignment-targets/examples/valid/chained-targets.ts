class Leaf {
  v: int;
  constructor(v: int) { this.v = v; }
}

class Node {
  kids: Leaf[];
  constructor(k: Leaf[]) { this.kids = k; }
}

class Holder {
  items: Leaf[];
  constructor(i: Leaf[]) { this.items = i; }
  bump(n: int): void { this.items[0].v += n; }
}

function pick(a: Leaf[]): Leaf {
  return a[0];
}

function main(): void {
  // index then field, the shape from the issue
  let arr: Leaf[] = [new Leaf(1), new Leaf(2)];
  arr[0].v = 42;
  console.log(`${arr[0].v} ${arr[1].v}`);

  // the write lands on the element itself, not on a copy
  let alias: Leaf = arr[1];
  arr[1].v = 7;
  console.log(`${alias.v}`);

  // a computed index
  let i: int = 0;
  arr[i + 1].v = 9;
  console.log(`${arr[1].v}`);

  // compound assignment through the same chain
  arr[0].v += 8;
  console.log(`${arr[0].v}`);

  // postfix increment through the same chain
  arr[0].v++;
  console.log(`${arr[0].v}`);

  // two indexes then a field
  let grid: Leaf[][] = [[new Leaf(1)]];
  grid[0][0].v = 5;
  console.log(`${grid[0][0].v}`);

  // field, index, field
  let node: Node = new Node([new Leaf(1), new Leaf(2)]);
  node.kids[1].v = 6;
  console.log(`${node.kids[0].v} ${node.kids[1].v}`);

  // index, field, index, field
  let nodes: Node[] = [new Node([new Leaf(3)])];
  nodes[0].kids[0].v = 11;
  console.log(`${nodes[0].kids[0].v}`);

  // the same chain under `this`, which already worked and must keep working
  let h: Holder = new Holder([new Leaf(10)]);
  h.bump(5);
  console.log(`${h.items[0].v}`);

  // a call result is a chain base like any other
  let owned: Leaf[] = [new Leaf(1)];
  pick(owned).v = 20;
  console.log(`${owned[0].v}`);

  // a chain statement that is not an assignment is still an expression
  console.log(`${arr[0].v > 0 ? "positive" : "not"}`);
}

main();
