// `embed(` written inside a string, a comment or a template is text. None of
// these name a file, so compiling at all is the assertion.
const quoted: string = "embed(\"./nowhere.txt\")";
const single: string = 'embedDir("./nowhere")';
const templated: string = `embed("./nowhere.txt")`;
// embed("./nowhere.txt")
/* embedDir("./nowhere") */
console.log(quoted + "|" + single + "|" + templated);
