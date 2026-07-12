class Vec {
  constructor(x, y) { this.x = x; this.y = y; }
  dot(o) { return this.x * o.x + this.y * o.y; }
  norm() { return this.x * this.x + this.y * this.y; }
}
function mix(a, b) { return (a * 7 + b * 13 + 5) % 251; }
function run(n) {
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
