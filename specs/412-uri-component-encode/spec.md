# 412 — `encodeURIComponent` / `decodeURIComponent`

## Problem

The standard URL-escaping globals were undefined, so building or parsing query
strings (natural alongside the `http` module) failed:

```ts
encodeURIComponent("a b&c"); // undefined variable 'encodeURIComponent'
```

## Approach

- **Runtime** (`lumen_compiler.zig` prelude): add `__encodeURIComponent` and
  `__decodeURIComponent` (plus `__uriHex`/`__uriUnhex` helpers). Encoding
  percent-escapes every byte except the RFC 3986 / JS unreserved set
  (`A–Z a–z 0–9 - _ . ! ~ * ' ( )`); decoding reverses `%XX`, passing malformed
  escapes through literally. Both build the result on the scratch arena
  (`__sa()`).
- **Check** (`lumen_check_expr.zig`): recognize the two globals as
  `string -> string`, requiring one string argument.
- **Emit** (`lumen_emit.zig`): lower to `__encodeURIComponent(x)` /
  `__decodeURIComponent(x)`.

## Verification

- `encodeURIComponent("a b&c")` → `a%20b%26c`.
- `"hello world!"` → `hello%20world!` (`!` unreserved); `"abc-_.~"` unchanged.
- `"a/b?c=d"` → `a%2Fb%3Fc%3Dd`.
- `decodeURIComponent("a%20b%26c")` → `a b&c`.
- Round-trip `decodeURIComponent(encodeURIComponent(s)) === s` → `true`.
- Full `zig build` + test suite green.
