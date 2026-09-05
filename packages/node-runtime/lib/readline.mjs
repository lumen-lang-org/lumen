// `readline.question(prompt)` (spec 058): writes the prompt to stdout and
// blocks for one line of stdin, returned without its line terminator; ""
// at end of input.
import { process as lumenProcess } from "./process.mjs";

export function question(prompt) {
  lumenProcess.stdout().write(prompt);
  let line = lumenProcess.stdin().readLine();
  if (line.length === 0) return "";
  if (line.endsWith("\n")) line = line.slice(0, -1);
  if (line.endsWith("\r")) line = line.slice(0, -1);
  return line;
}
