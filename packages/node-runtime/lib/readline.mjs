// `readline.question(prompt)` (spec 058): writes the prompt to stdout and
// blocks for one line of stdin, returned without its line terminator; ""
// at end of input.
//
// Spec 508 T008's decision: this does NOT go through the I/O broker.
// `question` never takes a timeout (spec 058's contract is "block", not
// "block up to ms"), and stdin's own blocking, synchronous `readLine()`
// (`ReadableStream` in `lib/streams.mjs`, spec 046/053) already blocks this
// thread correctly on its own via `fs.readSync` -- the broker exists to run
// a *timer* or a *second* process's I/O underneath an `Atomics.wait` that
// this thread's own blocking read doesn't need. Routing this through the
// broker would add a cross-thread round trip for no behavior it doesn't
// already have.
import { process as lumenProcess } from "./process.mjs";

export function question(prompt) {
  lumenProcess.stdout().write(prompt);
  let line = lumenProcess.stdin().readLine();
  if (line.length === 0) return "";
  if (line.endsWith("\n")) line = line.slice(0, -1);
  if (line.endsWith("\r")) line = line.slice(0, -1);
  return line;
}
