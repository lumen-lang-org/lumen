// The type a decorator returns, in a module of its own: the decorated program
// imports it to name the generated constant's type, and the decorator imports
// it to build one. The decorator's module itself never reaches the program.

export type Column = {
  field: string,
  column: string,
};

export type Shape = {
  table: string,
  columns: Column[],
  count: int,
};
