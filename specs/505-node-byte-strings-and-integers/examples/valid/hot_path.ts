function count(text: string, needle: string): int {
  let n = 0;
  let i = text.indexOf(needle);
  while (i >= 0) {
    n = n + 1;
    i = text.indexOf(needle, i + 1);
  }
  return n;
}
const parts = ["a=1", "b=2", "c=3"];
let joined = "";
for (const p of parts) { joined = joined + p + ";"; }
console.log(joined.length);
console.log(count(joined, "="));
console.log(joined[2] == "1");
console.log(joined.slice(0, 3));
