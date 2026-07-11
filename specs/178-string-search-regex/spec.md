# Spec 178: `string.search` with a regex

## Goal

Support `String.prototype.search(regex)`, returning the index of the first match
or -1:

```ts
"abc123".search(/[0-9]/);   // 3
"abcdef".search(/[0-9]/);   // -1
```

Completes the regex string-method set (`replace`/`replaceAll` spec 175,
`split` spec 176) using the same match-span infrastructure.

## Why additive, not breaking

`search` was previously unsupported (reported `E_TYPE_MISMATCH`); this only adds
the regex form.

## Semantics

`s.search(re)` returns the byte index of the leftmost regex match in `s`, or -1
if there is none. The `g` flag has no effect (search always reports the first
match, as in JS). The `i` flag is honored.

## Implementation

- Runtime (`regex_rt.zig`): `searchRegex` returns the first `__reFind` span's
  start, or -1.
- Checker: a `search` call with one `regexp` argument sets `regex_arg`, flags
  `program.uses_regex`, and returns `i32`.
- Emit: `emitStringMethod` routes a `regex_arg` search to
  `searchRegex(source, flags, receiver)`.

## Requirements

- **FR-001**: `s.search(/re/)` returns the first match index, or -1.
- **FR-002**: The `i` flag is honored; `g` does not change the result.

## Success Criteria

- **SC-001**: `"abc123".search(/[0-9]/)` -> `3`; `"abcdef".search(/[0-9]/)` -> `-1`.
- **SC-002**: `"hello world".search(/world/)` -> `6`.
- **SC-003**: A regex bound to a variable works as the pattern.
- **SC-004**: `zig build`, `zig build test`, and the `regex_rt.zig` unit test
  stay green.
