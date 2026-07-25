// A class stringifies as a record of its fields, and parses back.
class Agent {
  id: string;
  maxSteps: int;
  constructor(id: string, maxSteps: int) {
    this.id = id;
    this.maxSteps = maxSteps;
  }
  describe(): string { return this.id + ":" + `${this.maxSteps}`; }
}
let a = new Agent("a1", 5);
let json = JSON.stringify(a);
let back: Agent = JSON.parse<Agent>(json);
console.log(json + "|" + back.describe());
