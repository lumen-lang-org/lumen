// Single-argument reduce/reduceRight (no seed) is valid since spec 132 --
// the first element seeds the accumulator, matching JS. Zero arguments is
// still rejected (lumen_check_methods.zig only accepts 1 or 2).
let xs: int[] = [1, 2, 3];
let sum = xs.reduce();
console.log(sum);
