// Array.from lowers to its own block with its own temporaries.
const chars: string[] = Array.from(Array.from("abc"));
console.log(chars.length);
const bumped: int[] = Array.from(Array.from([1, 2, 3], (x: int): int => x * 2), (y: int): int => y + 1);
console.log(bumped[0] + bumped[1] + bumped[2]);
