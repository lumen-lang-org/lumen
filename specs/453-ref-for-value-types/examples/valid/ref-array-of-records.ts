// an array of records, with a field read through the reference.
type P = { x: int };
function grow(ps: Ref<P[]>): void {
  let q: P = { x: 9 };
  ps = [...ps, q];
}
let list: P[] = [];
grow(list);
console.log(`${list.length},${list[0].x}`);
