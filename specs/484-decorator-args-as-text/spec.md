# Spec 484: a decorator's arguments, also as text

## Goal

```ts
@checked
class Ask {
  @maxLength(200, "that is not a site key")
  siteKey: string;
}
```

A decorator that wants to read those two arguments could not, and the reason was
not the protocol's shape but Lumen's type system.

## Why

`lumen describe` already hands a class decorator every field and every
decorator written on it, arguments included:

```json
{"name":"siteKey","type":"string",
 "decorators":[{"name":"maxLength","args":[200,"that is not a site key"]}]}
```

The description is narrowed into the `Description` type the decorator's module
declares, and `args` there is `[200, "that is not a site key"]` — an int beside a
string. A Lumen array is homogeneous, so there is no type a `Description` can
declare for that field. `args: string[]` refuses the int, `args: int[]` refuses
the string, and the decorator fails with `JSON.parse: invalid JSON`.

So every argument a decorator carries was unreachable to any decorator that took
more than one kind.

## The rule

> Every decorator description carries `argsText` beside `args`: the same
> arguments in the same order, each spelled as a string. A `Description` may
> declare `argsText: string[]` and receive them all.

`200` becomes `"200"`, `true` becomes `"true"`, `1.5` becomes `"1.5"`. A
decorator parses back what it needs, which it must do anyway to decide what an
argument means.

## Backward compatible, and the tests are the proof

`args` is untouched. A `Description` that does not declare `argsText` narrows
exactly as before — narrowing keeps only the fields the type declares, so an
added field cannot reach a decorator that never asked for it.

`packages/rest`'s `@controller` is the existing consumer and its suites were not
edited: `controller.test.ts` 12 passed, `mount.test.ts` 14 passed, against the
new compiler.

What did change is `lumen_describe.zig`'s own golden strings, which assert the
emitter's exact output and therefore had to gain the field they now emit.
