// A #private field is unreachable from outside the class, so it stays out of
// a document that crosses a process boundary — while remaining usable inside.
class Secretive {
  id: string;
  #token: string;
  constructor(id: string, t: string) { this.id = id; this.#token = t; }
  reveal(): string { return this.#token; }
}
let s = new Secretive("a1", "sk-SECRET");
let parsed: Secretive = JSON.parse<Secretive>("{\"id\":\"b2\"}");
console.log(JSON.stringify(s) + "|" + s.reveal() + "|" + parsed.id + "|[" + parsed.reveal() + "]");
