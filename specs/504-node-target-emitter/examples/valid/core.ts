enum Color { Red, Green, Blue }

class Shape {
  constructor(private name: string) {}
  describe(): string { return this.name; }
}

class Square extends Shape {
  constructor(public side: int) { super("square"); }
  area(): int { return this.side * this.side; }
}

function tag(kind: Color): string {
  switch (kind) {
    case Color.Red: return "red";
    case Color.Green: return "green";
    default: return "blue";
  }
}

const shapes: Square[] = [new Square(2), new Square(3)];
let total = 0;
for (const s of shapes) { total += s.area(); }
console.log(shapes[0].describe() + " " + `${total}`);
console.log(tag(Color.Green));

const words = ["b", "a", "c"].toSorted();
console.log(words.join(","));

let maybe: string | null = null;
console.log(maybe ?? "none");

try {
  throw new Error("boom");
} catch (e) {
  console.log("caught " + e.message);
} finally {
  console.log("done");
}
