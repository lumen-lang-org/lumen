// An array method inside another array method's callback and argument.
const grid: int[][] = [[1, 2], [3, 4]];
const sums = grid.map((row: int[]): int => row.reduce((a: int, b: int): int => a + b, 0));
console.log(sums[0] + sums[1]);
const n: int[] = [5, 1, 4, 9];
console.log(n.slice(0, n.slice(1, 3).length).length);
