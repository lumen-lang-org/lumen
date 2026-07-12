// Allocation-free hot loop: inferred-return functions + this-based method
// dispatch on a single reused instance. State bounded < 2^15 so i32 products
// never overflow and results match JS exactly.
class Kernel {
  a: i32;
  b: i32;
  constructor(a: i32, b: i32) { this.a = a; this.b = b; }
  next(x: i32) { return (x * this.a + this.b) % 32749; }   // return inferred, this-based
}
function scramble(x: i32) { return (x * 13 + 7) % 32749; }  // return inferred

function run(n: i32) {
  const k = new Kernel(1103, 12345 % 32749);
  let acc = 1;
  for (let i = 0; i < n; i = i + 1) {
    acc = k.next(scramble(acc + (i % 32749)));
  }
  return acc;
}
console.log(run(100000000));
