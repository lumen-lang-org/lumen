class P {
  constructor(x, y) { this.x = x; this.y = y; }
  energy() { return this.x * this.x + this.y * this.y; }
}
function run(n) {
  let acc = 0, sx = 1, sy = 2;
  for (let i = 0; i < n; i = i + 1) {
    const p = new P((sx * 7 + i) % 251, (sy * 13 + i) % 251);
    acc = (acc + p.energy()) % 1000000007;
    sx = (acc % 250) + 1;
    sy = ((acc + i) % 250) + 1;
  }
  return acc;
}
console.log(run(20000000));
