# Spec 487: assigning to a field reached through a chain

## Goal

```ts
class Box { val: int; constructor(v: int) { this.val = v; } }

function main(): void {
  let arr: Box[] = [new Box(1)];
  arr[0].val = 42;
  console.log(`${arr[0].val}`);
}
```

Today that fails to parse, and the message names the `=` rather than anything
about assignment targets:

```
repro.ts:6:14: error: expected end of statement (';' or a newline), found '='
  6 |   arr[0].val = 42;
    |              ^
```

Reading the same place is fine (`console.log(arr[0].val)` compiles), calling
through it is fine (`arr[0].bump()` compiles), and binding the element to a
local first and writing through that compiles and mutates the same object:

```ts
let b: Box = arr[0];
b.val = 42;      // works, and `arr[0].val` is then 42
```

So the write is expressible and the semantics already exist. Only the spelling
`arr[0].val = 42` is rejected.

## Why it is refused

Not by a rule, and not by the checker. `parseStmt` (`src/lumen_parser.zig`)
handles a statement that begins with an identifier in stages, and the stage
that matches this shape does not look for an assignment operator.

After consuming the leading identifier, the parser tries, in order:

1. `name(` — a call statement.
2. `name.field` followed directly by `=` or a compound operator — the
   single-level member write, which is where `obj.field = value` is recognised.
3. `name` followed by `.`, `[`, or `?.` — a member-expression statement. This
   rewinds to the identifier, parses the whole thing with `parseExpr`, and then
   calls `expectSemi`.

`arr[0].val = 42` reaches stage 3, because the token after `arr` is `[` and not
`.`. `parseExpr` parses `arr[0].val` correctly, stops at the `=` (no
precedence level in the expression grammar consumes an assignment operator),
and `expectSemi` reports the `=` it did not expect. Stage 2 never applies,
because it is written for exactly one `.field` directly after the identifier.

The same stage-3 gap rejects every other chained target for the same reason:

```ts
o.inner.v = 42;         // two levels of field
grid[0][0].val = 42;    // two indexes then a field
b.items[0].val = 42;    // field, index, field
```

`this.items[0].val = 42` inside a method already works, and that is the tell.
The `this` branch of `parseStmt` parses its chain with `parsePostfixFrom` and
then explicitly checks for a trailing assignment operator, building a
`member_assign` whose `obj` is the whole `this.items[0]` expression. Everything
downstream of the parser — checker routing, emission, the reference semantics
that make the write land on the array's element rather than a copy — is already
in place and exercised by that path. The identifier-led branch simply never
grew the same trailing check.

## The rule

> A statement whose target is a chain of field accesses and indexes ending in a
> field access is a field write. `a.b`, `a[i].b`, `a.b.c`, `a[i][j].c`,
> `a.b[i].c`, and `f(x).b` are assignable; `=` and every compound assignment
> operator apply to them exactly as they apply to `obj.field`.

The chain must end in a field access. What that excludes stays excluded:

- `f() = 5` and `1 = x` are not chains ending in a field and are rejected.
- `a.b() = 5` ends in a call, and is rejected as an invalid assignment target.
- `a?.b = 5` ends in an optional field access. Writing through a link that may
  be absent has no meaning, so it is rejected too.
- `a[i] = v` and `a[i][j] = v` end in an index. These are writes into the
  container, which stay refused because arrays and records are immutable, and
  both spellings now say so with the same message.

Reaching a field through an index does not make the array mutable. The array
slot is not written; the object it refers to is, which is the same thing the
local-variable workaround does today.

## Conformance

`examples/valid/chained-targets.ts` covers the shapes the rule admits and
checks the mutation is observable through the original container, including
through a second binding aliasing the same element. The invalid examples pin
each rejected form to its diagnostic.
