# Tasks: spec 058 readline

- [ ] **T1 -- `readline.question(prompt)`.** Files: `src/lumen_parser.zig`
  (`isStdNamespace` gains `"readline"`), `src/lumen_check_stdlib.zig`
  (`readlineCallType`, dispatched from `staticCallType`), `src/lumen_emit.zig`
  (static-call emit branch calling a new `__readlineQuestion` runtime
  function), `src/lumen_compiler.zig` (`needs_readline` flag gating the
  runtime block; reuses `__processStdout`/`__processStdin` verbatim -- no
  new stream type). `src/lumen_ast.zig` gains `needs_readline: bool = false`
  on `Program`. Verify: piped single-line input, piped multi-line input
  (two `question()` calls in sequence), and exhausted-input EOF -- all via
  real shell piping through the compiled binary, not just a compile check.
