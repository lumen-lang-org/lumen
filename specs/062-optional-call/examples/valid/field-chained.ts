// obj.cb?.() -- optional call chained off a field access.
type Cb = () => int;

class Box {
  cb: Cb | null;
  constructor(cb: Cb | null) {
    this.cb = cb;
  }
}

const full = new Box(() => 77);
const empty = new Box(null);
console.log(full.cb?.() ?? -1);
console.log(empty.cb?.() ?? -1);
