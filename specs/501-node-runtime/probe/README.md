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

## Autonomous implementation

Specs 502–508 carry `plan.md` and `tasks.md`; `tools/workflows/node-target.js`
drives them end to end: preflight, then per spec an implement → gate → review →
fix loop until `tasks.md` is fully ticked and the gate is green, the full
corpus after each spec, then Joule's spec 004, then `STATUS.md`. Launch it from
a Claude Code session with the Workflow tool:

```
Workflow({ scriptPath: "tools/workflows/node-target.js",
           args: { specs: ["502-string-literal-newline", "503-node-runtime-package"] } })
```

`args.specs` narrows the run (default: 502–507 in order); `maxRounds` caps
the fix loop per spec (default 6); `skipJoule: true` stops before Joule. The
toolchain it needs is installed by `sh tools/node-target-env.sh`.
