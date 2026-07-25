# Feature Specification: Methods In A Class Description

## Problem

Spec 455 parses decorators on class members, and the parser keeps them: a
method's own decorators land on its `FunctionDecl`, a parameter's on its
`FunctionParam`. The description a decorator is handed then drops all of it —
`writeClass` emits `fields` and stops (`src/lumen_describe.zig:98`).

So this class describes as if `find` did not exist:

```ts
@controller("/agents")
class AgentApi {
  @get("/:id")
  find(@param("the id") id: string): string { return id; }
}
```

```json
{"protocol":1,"kind":"class","name":"AgentApi","args":["/agents"],"file":"api.ts","line":2,"fields":[]}
```

A decorator that exists to turn methods into routes — the shape every server
framework built on decorators has — cannot see a single one of them. The
information is in the AST; only the description is missing it.

## What this adds

A `methods` array on the class description, one entry per method in source
order:

```json
"methods": [
  { "name": "find", "returns": "string",
    "params": [ { "name": "id", "type": "string",
                  "decorators": [ { "name": "param", "args": ["the id"] } ] } ],
    "decorators": [ { "name": "get", "args": ["/:id"] } ] }
]
```

An entry is the function description's own shape (`name`, `params`, `returns`,
each parameter with its `decorators`) plus the method's own `decorators`, so a
decorator reads a method exactly as it reads a decorated free function. `type`
and `returns` are the annotations **as written**: a description is syntax, not
types, and an omitted return annotation describes as `""`.

A class with no methods describes `"methods":[]`. The key is always present, so
a decorator never asks whether it exists.

`protocol` stays 1: the field is additive.

## Not planned here

- **Which members are described.** Constructors are not methods here (they are
  not in `ClassDecl.methods`), and getters/setters describe as the methods they
  are stored as, without a marker saying so. `static` is likewise not reported.
  Nothing reads those yet; each is one field when something does.
- **Decorators on methods and parameters running.** They are data for the class
  decorator to read, resolved by nobody — the standing field decorators already
  have (spec 455).

## A decorator is handed only what it asked for

`JSON.parse` accepts only the keys its target type declares. So the first cut
of this feature was not additive at all: adding `methods` took the 455 suite
from ten passing cases to six, every one of them a class decorator, each dying
with `JSON.parse: invalid JSON (UnknownField)`. Every decorator anyone had
written would have broken on a compiler upgrade, and the format could never
have grown again — which would make `protocol` a number nobody can use, since
the version a decorator refuses would never be the version that reaches it.

The compiler now narrows the description before handing it over
(`narrow` in `src/lumen_decorator.zig`): it reads the decorator module's own
`Description` type — already parsed, to check the decorator's signature — and
drops every key that type does not declare, recursively, through arrays and
nested record types alike. A decorator that names `fields` and not `methods`
is handed a description with no `methods` in it.

Narrowing only ever removes. A key the type declares and the description does
not is left missing and fails the decorator's parse, which is the right answer:
it asked for something the compiler does not describe.

The 455 decorators are therefore unchanged by this spec, and one of them —
`caption`, declaring exactly the seven keys spec 455 had — is a conformance
case here, run against a class with decorated methods.

## Conformance

`specs/459-method-descriptions/conformance/manifest.json`:

| case | phase | proves |
| --- | --- | --- |
| `methods.valid.decorated-methods-reach-the-decorator` | compile-run | a `@routes` class decorator reads each method's decorator, its parameters and their decorators as written, and its return type — including a method nobody decorated |
| `methods.valid.class-without-methods-describes-an-empty-array` | compile-run | a class with no methods parses against a `Description` declaring `methods`, so the key is present and empty rather than absent |
| `methods.valid.a-decorator-that-never-heard-of-methods-still-runs` | compile-run | a decorator declaring only spec 455's seven keys runs against a class with decorated methods — the description is narrowed to what it asked for |
