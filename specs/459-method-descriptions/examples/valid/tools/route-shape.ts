// The type the `@routes` decorator returns, in a module of its own: the
// decorated program imports it to name the generated constant's type, and the
// decorator imports it to build one.

export type Route = {
  verb: string,
  path: string,
  handler: string,
  params: string,
  returns: string,
};

export type Routes = {
  base: string,
  routes: Route[],
  count: int,
};
