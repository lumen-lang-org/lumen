// The spec's reproduction: a string method whose argument is another string
// method on the same receiver.
function tail(text: string): string {
  let rest = text.substring(1, text.length);
  return rest.substring(0, rest.indexOf("!"));
}
console.log(tail("xabc!def"));
