# Probe: how far is a Lumen program from running on Node?

Measurement scripts behind spec 501. They take a Lumen program's checkout
(Joule Code was the subject) and report, without changing the program:

- `sweep.mjs` — strips types with `node:module.stripTypeScriptTypes` and
  parses every `src/**/*.ts`; lists the files JavaScript's grammar rejects.
- `run_tests.mjs` — imports every `src/**/*.test.ts` in a child Node process
  that preloads `lumen_node_prelude.mjs`, runs its `test()` blocks, and
  tabulates loaded/pass/fail with the first cause per failure.
- `lumen_node_prelude.mjs` — a prototype of the runtime package: Lumen's
  global namespaces (`fs`, `path`, `crypto`, `process.platform()`,
  `process.sleep`, `argsCount`/`arg`, `test`/`expect`, ...) in Lumen's call
  shapes over Node's built-ins. Measurement quality, not a product.

Run from the program's root, with Node 22.18 or newer (type stripping on by
default):

```sh
node path/to/probe/sweep.mjs
node path/to/probe/run_tests.mjs
```

`sweep.mjs` writes the stripped files under the system temp directory (set
`S` to choose another).
