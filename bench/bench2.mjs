class Kernel {
  constructor(a, b) { this.a = a; this.b = b; }
  next(x) { return (x * this.a + this.b) % 32749; }
}
function scramble(x) { return (x * 13 + 7) % 32749; }
function run(n) {
  const k = new Kernel(1103, 12345 % 32749);
  let acc = 1;
  for (let i = 0; i < n; i = i + 1) {
    acc = k.next(scramble(acc + (i % 32749)));
  }
  return acc;
}
console.log(run(100000000));
