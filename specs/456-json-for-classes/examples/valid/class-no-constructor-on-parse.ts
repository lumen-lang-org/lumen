// Parsing fills fields without calling the constructor: a document knows
// nothing of a constructor's arguments, and reading a value should not run
// whatever work one does.
class Counted {
  id: string;
  constructor(id: string) {
    this.id = id;
    console.log("constructed");
  }
}
let p: Counted = JSON.parse<Counted>("{\"id\":\"a1\"}");
console.log("parsed " + p.id);
