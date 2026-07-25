// An independent module in the shape of a storage package. Its `persist` takes
// a parameter named `json` — a name it has no way of knowing another package
// exports as a function.
export function persist(table: string, json: string): string {
  return `${table}<-${json}`;
}
