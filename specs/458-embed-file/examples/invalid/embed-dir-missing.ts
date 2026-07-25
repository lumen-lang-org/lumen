type SqlFile = { name: string, text: string };
const files: SqlFile[] = embedDir("./not-a-directory");
console.log(files.length);
