# Spec 251: website reflects exception propagation and diagnostics DX

## Goal

The site's error-handling story matches the language: the try/catch example
now throws from a called function (specs 245/247/248) instead of only
lexically inside the try, and a new "Errors that explain themselves" section
shows real `lumen check` / `lumen run` / `lumen test` output — expected/got
diagnostics, did-you-mean, may-be-null guidance, truthiness hints, runtime
stack traces with cross-file origins, and the concise test report.

## Semantics

- `website/index.html` #errors section: cross-function throw example
  (verified to compile and run with the shown output, both `int` and `i32`
  spellings).
- New #dx section with sample terminal output drawn from the real CLI.
- The "Error handling" feature card mentions propagation and stack traces.

## Success Criteria

- **SC-001**: The example on the page runs and prints exactly the commented
  output.
- **SC-002**: No other sections changed.
