# Spec 234: extensionless local imports

## Goal

Accept the common TypeScript import style without the `.ts` extension:

```ts
import { double, GREETING } from "./util"    // resolves ./util.ts
```

Previously only `"./util.ts"` worked; the extensionless form (what most TS
codebases write) reported `E_UNSUPPORTED_IMPORT`.

## Semantics

A local relative import (`./x`, `../x`) whose specifier lacks the `.ts`
extension resolves by appending `.ts`. Explicit `.ts` specifiers and `https://`
URL imports (which must spell their extension) are unchanged.

## Success Criteria

- **SC-001**: `import { f } from "./util"` compiles and runs identically to the
  `.ts` form.
- **SC-002**: `.ts`-suffixed and URL imports behave as before.
- **SC-003**: `zig build` and `zig build test` stay green.
