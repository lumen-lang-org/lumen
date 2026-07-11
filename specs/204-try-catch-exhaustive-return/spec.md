# Spec 204: a try/catch where both branches return satisfies the return check

## Goal

Let a function end with a try/catch whose try and catch bodies both return,
without a redundant trailing `return`:

```ts
function parseOr(n: i32): i32 {
  try {
    if (n < 0) throw new Error("neg");
    return n;
  } catch (e) {
    return -1;
  }
}
```

Previously this reported `E_MISSING_RETURN` — the return-path analysis did not
consider try/catch. Companion to spec 200 (switch) and 203 (blocks).

## Why additive, not breaking

Only makes previously-rejected programs compile. Functions that already returned
on all paths and try/catch used for side effects are unchanged.

## Semantics

A try/catch counts as returning on all paths when it has a catch clause and both
the try body and the catch body return on all paths. A try with no catch does
not.

Because the try body's throw lowers to a break out of the try block, a
return-exhaustive try that can throw would leave Zig unable to prove the outer
block never falls through; the emit now appends an `unreachable` after the catch
in that case so the generated function type-checks.

## Requirements

- **FR-001**: A trailing try/catch with both bodies returning satisfies the
  return check, including when the try body throws.
- **FR-002**: A try with no catch, or with a non-returning try or catch body,
  still requires a trailing return.

## Success Criteria

- **SC-001**: `try { if (n<0) throw...; return n; } catch (e) { return -1; }` as
  the last statement compiles; `f(5)=5`, `f(-1)=-1`.
- **SC-002**: `try { return n>0?"pos":"neg"; } catch (e) { return "err"; }`
  works.
- **SC-003**: A try whose catch does not return still reports
  `E_MISSING_RETURN`.
- **SC-004**: A plain statement-level try/catch is unchanged.
- **SC-005**: `zig build` and `zig build test` stay green.
