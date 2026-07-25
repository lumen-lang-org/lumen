// An optional chain nested inside another's unwrapped branch: the payload
// capture is a generated name too.
const idx: int[] | null = [1, 0];
const vals: int[] | null = [7, 8];
console.log(vals?.[idx?.[0] ?? 0] ?? -1);
