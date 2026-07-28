// `Class.decorator` names a decorator the class does not carry. The constant
// spec 455 would have emitted does not exist, so this is an error at the call,
// naming the class and the decorator — not a null at run time.

class Plain {
  n: int = 1;
}

type Row = {
  table: string,
};

function main(): void {
  let p = new Plain();
  let r: Row = Class.decorator(p, "entity");
  console.log(r.table);
}

main();
