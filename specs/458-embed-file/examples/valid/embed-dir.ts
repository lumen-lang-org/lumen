// A directory becomes an array of { name, text }, sorted by name so two builds
// of unchanged sources produce the same program. The compiler reads no meaning
// into a name -- that V2 follows V1 is this program's conclusion, not its.
type SqlFile = { name: string, text: string };
const files: SqlFile[] = embedDir("./sql");
console.log(files.length);
for (const f of files) {
  console.log(f.name + " -> " + f.text.length);
}
console.log(files[2].text);
