# Spec 482: exporting a class

## Goal

```ts
// banner-api.ts
@controller("/banner")
export class BannerApi {
  @get("/") show(req: Request): Reply { return ok(bannerJson(this.db)); }
}
```

```ts
// api.ts
import { BannerApi } from "./banner-api.ts";
listen(8100, [new BannerApi(db)]);
```

Today the import fails, and not with a message about classes:

```
api.ts:1:1: error: unsupported import syntax [E_UNSUPPORTED_IMPORT]
```

## Why it is refused

Not by a rule. `parseNamedExportDecl` (`src/lumen.zig:335`) recognises four
prefixes:

```zig
"export function ", "export const ", "export let ", "export type ",
```

Anything else beginning with `export ` reaches the catch-all at
`src/lumen.zig:1420` and becomes `error.InvalidImport`. `export class` was
never added to the list, so a module containing one cannot be imported at all
— including for its functions, which is why the diagnostic names the import
rather than the class.

The rest of the machinery is already there:

- `scanTopLevelDecls` (`src/lumen.zig:747`) lists `class ` among the top-level
  keywords, strips a leading `export `, tracks the multi-line body through
  `braceDelta`, and records `.exported`. Namespacing and renaming across
  modules already treat a class like any other declaration.
- A **non-exported** class in an imported module already works. Three cases,
  isolated: a module exporting a function imports fine; the same module with
  `export class` added fails at every import site; removing the `export`
  keyword fixes it again. The class was never the problem.

Because the flattener is line-oriented, a class needs no more than the other
four forms: strip `export ` from the line that opens the declaration and the
indented body lines flow through untouched.

## The rule

> `export class C { … }` exports `C` under its own name, as `export function`
> exports a function. The declaration is spliced into the flat program with the
> `export ` keyword removed; the class body is unchanged. An importing module
> names `C` in its import clause and uses it as if it were declared locally —
> `new C(…)`, a type annotation, `Class.nameOf`, `Class.decorator`.

Same collision rule as every other exported name: two modules exporting `C` are
renamed apart by the namespacing that already runs, not reported as an error.

Decorators come along, because they already do. `@controller` leaves a
`controllerC` constant beside the class in the same flat program, and
`Class.decorator(c, "controller")` resolves to it there. Nothing about the
metadata is per-module.

## Also missing, same list

`export interface` and `export enum` fail the same way and for the same
reason. Both are in `scanTopLevelDecls`'s keyword table and absent from
`parseNamedExportDecl`'s. They are fixed with the same change.

## What this unblocks

`std-contrib/packages/agents/api.ts` is 7,908 lines holding 46 controllers and
215 routes, and it cannot be split, because a controller is a class and a class
cannot leave the file that mounts it. The package works around it by keeping
every class in one file and moving only the free functions out — which
CLAUDE.md names as the thing not to do:

> Never work around a compiler limitation in user code. If a std-contrib
> package has to rename a parameter, restructure a type, or avoid a name
> because the compiler cannot cope, that is a compiler bug. Fix the compiler.
