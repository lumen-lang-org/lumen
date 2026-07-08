// Divergence from real TS (documented in spec.md): `?.` short-circuits
// LOCALLY, not the whole trailing chain. `cb?.()` yields `Rec | null`, not
// `Rec` -- continuing the chain needs its own `?.`. A plain `.v` here would
// be E_TYPE_MISMATCH. Real TS would let `a?.b().c` short-circuit the whole
// chain to `undefined` after one `?.`; Lumen requires `cb?.()?.v`.
type Rec = { v: int };
type Cb = () => Rec;

function makeRec(): Rec {
  return { v: 42 };
}

class Box {
  cb: Cb | null;
  constructor(cb: Cb | null) {
    this.cb = cb;
  }
}

const full = new Box(makeRec);
console.log(full.cb?.()?.v ?? -1);

const empty = new Box(null);
console.log(empty.cb?.()?.v ?? -1);
