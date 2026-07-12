// Every `new P(...)` is used only as a method receiver, so escape analysis
// stack-allocates all of them: zero heap in the hot loop.
class P {
  x: i32;
  y: i32;
  constructor(x: i32, y: i32) { this.x = x; this.y = y; }
  energy() { return this.x * this.x + this.y * this.y; }  // receiver-only, returns i32
}
function run(n: i32) {
  let acc = 0;
  let sx = 1;
  let sy = 2;
  for (let i = 0; i < n; i = i + 1) {
    const p = new P((sx * 7 + i) % 251, (sy * 13 + i) % 251);
    acc = (acc + p.energy()) % 1000000007;
    sx = (acc % 250) + 1;
    sy = ((acc + i) % 250) + 1;
  }
  return acc;
}
console.log(run(20000000));
