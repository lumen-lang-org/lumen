// Two generated temporaries in one function, in sequence and then nested.
function both(s: string): string {
  const head = s.substring(0, 5);
  const rest = s.substring(6, s.length);
  return head + "|" + rest.substring(0, rest.indexOf("!")) + "|" + s.substring(0, s.indexOf(" "));
}
console.log(both("alpha beta!gamma"));
