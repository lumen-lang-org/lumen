# 361 — `string.match(regex)`

## Problem

`replace`/`replaceAll`/`split`/`search` accepted regex patterns, but `match` —
the most common "give me the matched text" API — was missing:

```ts
"a1b22".match(/[0-9]+/)   // error: `string` has no method 'match'
```

## Change

- **Runtime** (`regex_rt.zig`): `matchRegex(alloc, pattern, flags, input)`
  returns a one-element slice holding the first match's full text, or null on
  no match / malformed pattern.
- **Checker** (`lumen_check_methods.zig`): `match(pattern)` with a regex
  argument types as `string[] | null` (JS shape: element 0 is the full match),
  routed through the same `regex_arg` flag as the other regex string methods.
- **Emitter** (`lumen_emit_array_string.zig`): emits
  `@as(?[]const []const u8, __lumen_regex.matchRegex(...))`, mirroring the
  `search`/`split` emission.

## Verified

`zig build` + `zig build test` green. Probes, bit-identical to Node 22:

| program | Lumen | Node |
|---|---|---|
| `"a1b22".match(/[0-9]+/)` → `m[0]` | `1` | `1` |
| `"abc".match(/[0-9]+/)` → null path | `none` | `none` |
| `"hello world".match(/^hello/)` → `m[0]` | `hello` | `hello` |

## Boundary

Capture groups are not populated (the regex engine tracks match spans, not
per-group spans) and the `g` flag does not return all matches — element 0 is
the first match's full text, always a length-1 array. Documented V1 subset.
