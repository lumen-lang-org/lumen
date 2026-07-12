// Exercises session features: inferred-return functions, inferred class
// fields, this-based method return inference, method dispatch, non-null.
// Pure i32 arithmetic kept within range so results are bit-identical to JS.
class Vec {
  x = 0;
  y = 0;
  constructor(x: i32, y: i32) { this.x = x; this.y = y; }
  dot(o: Vec) { return this.x * o.x + this.y * o.y; }   // return inferred
  norm() { return this.x * this.x + this.y * this.y; }  // return inferred
}

function mix(a: i32, b: i32) { return (a * 7 + b * 13 + 5) % 251; }  // return inferred

function run(n: i32) {
  let acc = 0;
  let px = 1;
  let py = 2;
  for (let i = 0; i < n; i = i + 1) {
    const a = new Vec(px, py);
    const b = new Vec(mix(i, px), mix(py, i));
    acc = (acc + a.dot(b) + b.norm()) % 1000000007;
    px = (acc % 250) + 1;
    py = ((acc + i) % 250) + 1;
  }
  return acc;
}

console.log(run(20000000));
