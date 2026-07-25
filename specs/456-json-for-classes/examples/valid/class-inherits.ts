// A subclass emits its parent's fields first.
class Base { kind: string; constructor(k: string) { this.kind = k; } }
class Child extends Base {
  name: string;
  constructor(k: string, n: string) { super(k); this.name = n; }
}
console.log(JSON.stringify(new Child("animal", "rex")));
