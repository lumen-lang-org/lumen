# Spec 440 — Clearer diagnostic for `expr?.m()` on a temporary

## Problem

An optional method call `a?.m()` works when the receiver is a pure expression (a
variable, field, or index): it desugars to `a != null ? a.m() : null`. When the
receiver is impure — e.g. `map.get(k)?.toString()` — the receiver can't be
evaluated twice, so it's rejected. The message, however, claimed optional method
calls are unsupported outright:

```
error: optional method call (a?.m()) is not supported [E_UNSUPPORTED_OPTIONAL_CALL]
```

That is misleading (`v?.m()` on a variable does work) and gives no fix.

## Change

The rejection at the impure-receiver path (`lumen_check_expr.zig`) now reports
the actual situation and the one-line workaround:

```
error: optional method call on a temporary (`expr?.m()`) is not supported —
bind the receiver first: `const v = expr; v?.m()`
```

No behavior change — only the message. The pure-receiver desugar is unchanged.

## Verification

- `zig build` and `zig build test` clean.
- `map.get(k)?.toString()` reports the new guidance.
- `const v = map.get(k); v?.toString()` still compiles and runs.
