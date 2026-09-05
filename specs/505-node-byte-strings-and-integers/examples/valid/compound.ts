// Decision 2: integer `/=` and `%` on locals and fields truncate; a `number`
// field keeps its fraction; a namespace constant is a value; a `number`
// prints every digit.
class Gauge {
  ticks: int = 100;
  ratio: number = 100;
  constructor() {}
  halve(): void {
    this.ticks /= 8;
    this.ratio /= 8;
  }
}
let n: int = 17;
n /= 5;
console.log(n);
n %= 3;
console.log(n);
let wide: i64 = 9000000000;
wide /= 7;
console.log(wide);
const g = new Gauge();
g.halve();
console.log(g.ticks, g.ratio);
g.ticks /= 2;
console.log(g.ticks);
console.log(-7 % 3, 7 % -3);
const pi: number = Math.PI;
console.log(pi > 3.14, Number.MAX_SAFE_INTEGER);
const big: number = 1e21;
console.log(big, `${big}`, "v=" + big, big.toString());
console.log(Number.NaN, Number.POSITIVE_INFINITY);
