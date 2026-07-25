// An imported module embeds a file shipped beside its own source, so the path
// means the same thing wherever the importing program is compiled from.
import { note } from "./pkg/note";
console.log("[" + note + "]");
