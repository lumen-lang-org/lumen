# Spec 274: single-quoted strings

## Goal

The other half of JS string style works everywhere:

```ts
const a: string = 'hi'
const b: string = 'it\'s'
import { triple } from './util'
```

Previously `'` was a syntax error in expressions and an unresolvable
specifier in imports.

## Semantics

`'...'` lexes to the same string token as `"..."` (same escape handling).
Import and re-export specifiers accept either quote style. Content is
identical regardless of the quote used.

## Success Criteria

- **SC-001**: Single-quoted literals (including an escaped `\'`) print
  correctly and concatenate with double-quoted ones.
- **SC-002**: A single-quoted relative import resolves and runs.
- **SC-003**: `zig build` and `zig build test` stay green.
