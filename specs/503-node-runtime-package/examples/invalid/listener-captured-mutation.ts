// An arrow listener that assigns a captured `let` is refused for the same
// reason as any statement-body arrow (spec 153: captures are by value), and
// the refusal must be the one the reader can act on -- E_CAPTURED_MUTATION at
// the assignment -- not a type mismatch on the whole `on(...)` call.
const emitter = new EventEmitter<int>();
let total: int = 0;
emitter.on("add", (v: int) => { total = total + v; });
emitter.emit("add", 2);
console.log(total);
