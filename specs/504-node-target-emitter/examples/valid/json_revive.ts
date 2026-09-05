// JSON.parse<Class> revives an instance without running its constructor
// (spec 456): the public fields come from the document and a #private field
// takes its type's default -- through the whole inheritance chain, and for
// a class that has no constructor of its own.
class Base {
  kind: string;
  #stamp: string;
  constructor(k: string) { this.kind = k; this.#stamp = "stamped:" + k; }
  stamp(): string { return this.#stamp; }
}
class Child extends Base {
  name: string;
  #token: string;
  constructor(k: string, n: string) { super(k); this.name = n; this.#token = "t:" + n; }
  reveal(): string { return this.#token; }
}
let built = new Child("animal", "rex");
console.log(built.kind + "|" + built.name + "|" + built.stamp() + "|" + built.reveal());
let parsed: Child = JSON.parse<Child>("{\"kind\":\"plant\",\"name\":\"fern\"}");
console.log(parsed.kind + "|" + parsed.name + "|[" + parsed.stamp() + "]|[" + parsed.reveal() + "]");
console.log(JSON.stringify(parsed));
