// A file's contents become a string at compile time; nothing opens the file at
// run time and nothing has to ship beside the binary.
const greeting: string = embed("./fixtures/greeting.txt");
const nothing: string = embed("./fixtures/empty.txt");
console.log("[" + greeting + "]");
console.log("[" + nothing + "]");
