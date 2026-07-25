// Decorators on a function and on its parameters, likewise recorded and
// otherwise inert.
@tool("echo the phrase back")
function echoPhrase(@param("the phrase") phrase: string, @param("how many times") times: int): string {
  let out = "";
  let i: int = 0;
  while (i < times) {
    out = out + phrase;
    i = i + 1;
  }
  return out;
}

function main(): void {
  console.log(echoPhrase("ab", 3));
}

main();
