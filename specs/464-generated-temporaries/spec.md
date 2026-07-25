# Feature Specification: Generated Temporaries Must Not Collide

## Problem

Two string operations in one function, where the second reads a value the first
produced, fail to compile:

```ts
function tail(text: string): string {
  let rest = text.substring(1, text.length);
  return rest.substring(0, rest.indexOf("!"));
}
```

```
shadow_s.ts:3:3: error: local constant '__s' shadows local constant from outer scope
note: the native backend rejected this statement's generated code —
      likely a Lumen compiler bug; please report it
```

The note is right for once: this is a compiler bug. `substring` emits a
temporary called `__s`, and two of them in overlapping scopes collide. Nothing
in the program is wrong, and no rewording of the source is a fix — only
splitting the expression across statements, for a reason the message does not
explain.

Unlike the shadowing reports in specs 457 and 461, this one is not about the
flat namespace. The colliding names are the compiler's own, invented during
emission, and it invented the same one twice.

## Scope

In scope:

- A generated temporary is unique within the function it is emitted into.
- Every emitter that introduces one is covered, not only `substring`. The
  audit is the work: `__s` is one name, and a survey of the emitters will find
  the others.

Out of scope:

- Renaming user bindings. This is entirely about compiler-generated names.
- The `__` convention itself, which is right — the fault is reusing one name,
  not the prefix.

## Design

### D1 — a counter, not a fixed name

An emitter that needs a temporary takes the next number from a per-function
counter: `__t0`, `__t1`. A fixed name is what makes two of them collide, and no
amount of care about scopes fixes that when expressions nest arbitrarily.

### D2 — the audit

Every `__`-prefixed local the emitters introduce is found and moved onto the
counter. A grep for the literal names in `src/lumen_emit*.zig` is the starting
point, and the reproduction above shows the shape to look for: a temporary
introduced for the *receiver* of a method call, which nests whenever the
receiver is itself such a call.

### D3 — the reproduction becomes a conformance case

Nested-receiver cases for each string and array method that emits a temporary,
so this cannot come back one method at a time.

## Success Criteria

1. The reproduction above compiles and prints `abc`.
2. Three levels of nesting compile.
3. Two independent temporaries in one function do not collide, in sequence or
   nested.
4. `zig build test` passes; `zig build conformance` adds no new failures.

## Notes

Found writing a test helper for plume's ordering — `rest.substring(0,
rest.indexOf("\""))`, which is an ordinary thing to write. Worth noting that
the diagnostic did its job: it said a compiler bug had been hit, and it had.
The specs either side of it (457, 461) say the same words about problems that
are *not* compiler bugs, which is why they were worth separating.
