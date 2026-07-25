// Quotes, backslashes, tabs and newlines survive the trip into the program.
const tricky: string = embed("./fixtures/tricky.txt");
console.log(tricky.length);
console.log(tricky);
