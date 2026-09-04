# Changelog

All notable changes to the Lumen compiler, its standard library and its
tooling.

Lumen follows [Semantic Versioning](https://semver.org/) with the pre-1.0
caveat that section applies: while the major version is `0`, the **minor**
version carries breaking changes and the **patch** version carries additions
and fixes. `0.7.6 → 0.7.7` never breaks a program that compiled before;
`0.7.x → 0.8.0` may.

`lumen version` reports the version the binary was built from. A build made
from a checkout rather than a tag reports a string containing `dev`, so a
release is always distinguishable from a working-tree build.

> Releases up to and including 0.7.6 shipped without notes. Their entries
> below were reconstructed from the git history between tags, so they record
> what changed rather than what was announced at the time. Entries from the
> first release published after this file was added are written as the work
> lands.

## [Unreleased]

### Documentation

- The standard-library reference now documents seven `crypto` functions that
  had shipped without pages: `sha1`, `sha1Bytes`, `base64Encode`,
  `base64Decode`, `randomKey`, `encrypt` and `decrypt`. The last three are
  the string-envelope form of AES-256-GCM added in spec 467, which manages
  the nonce itself; the page now says how they differ from the
  `Buffer`-facing `encryptSync`/`decryptSync`, where the caller owns it.
- `JSON.parseOpen<T>()` (spec 500), `process.sleep(ms)` (spec 475),
  `child_process.spawn` with its `ChildProcess` handle (spec 450) and
  `Promise.all([...])` (spec 286) are documented for the first time.
- The `Array` reference records `push`/`unshift` and the `for…of` iterators
  `keys()`/`values()`/`entries()`, and no longer describes the array
  representation as having "no growable-array machinery" — `push` in a loop
  is an amortized-O(1) append after the optimizer sees it.
- The language reference summary gains the type-level operators (`keyof`,
  indexed access, mapped types, and the `Partial`/`Pick`/`Omit`/`Record`
  family), user-defined type guards and `typeof` narrowing, `instanceof`
  and `implements`, `const enum` and record intersections, `using`
  declarations, and a section on the compile-time surface: decorators,
  `@must_use`, `Class.nameOf`/`decorator`/`invoke`, and
  `embed`/`embedDir`.
- The roadmap no longer lists as missing seven things that have shipped:
  `child_process.spawn`, the `process.stdin`/`stdout`/`stderr` streams,
  client-side streaming HTTP bodies, one-shot AEAD, `pbkdf2Sync`/
  `scryptSync`, `sort`, and WebSocket support (which shipped as a package,
  `std-contrib/websocket`, rather than a stdlib module). Each row now names
  the narrower thing that is actually still missing.
- `path.resolve`'s example rendered as `// /foo/bar` instead of
  `// <cwd>/foo/bar`, because the placeholder was unescaped and the browser
  swallowed it as an unknown element.
- `packages.html` linked to `/community#contribute`, an anchor that did not
  exist; `community.html`'s sections now carry ids.

## [0.7.6] — 2026-09-02

### Added

- `JSON.parseOpen<T>(text)`: `JSON.parse<T>` in every respect but one — a
  member the type does not declare is ignored instead of refused. For
  payloads written by something that is not this build of this program,
  where a sender adding a field would otherwise break every older receiver
  at once. A missing required field, a field of the wrong type, and
  malformed JSON are all still refused. (spec 500)
- `@must_use`: a marker on a function declaration saying its return value is
  the reason to call it. Discarding such a call as a statement warns. Spec
  271 already warned for array and string transforms; this lets a library
  author mark their own. (spec 499)

### Changed

- The async runtime chooses its event-loop backend at run time rather than
  at build time. (spec 498)
- Release archives are built on GitHub-hosted runners, so the five targets
  build at once instead of queueing.

## [0.7.5] — 2026-08-28

### Added

- `lumen compile --library-path <dir>`: name a directory to search for
  libraries. (spec 497)

### Fixed

- `HttpStream.read()` delivers bytes over TLS, not only plaintext. (spec 496)

## [0.7.4] — 2026-08-27

### Added

- `HttpStream.read()`: raw, undelimited reads past a `101` response, for
  binary frames where `readLine()`'s line-delimited semantics would corrupt
  or hang. (spec 495)

## [0.7.3] — 2026-08-27

### Added

- `HttpStream.write()`: raw bytes past a `101` response — what a caller
  completing a WebSocket handshake needs. (spec 494)

## [0.7.2] — 2026-08-24

### Added

- `lumen compile --target <triple>` and `--static`. (fixes #37)

## [0.7.1] — 2026-08-22

### Fixed

- `Map`/`Set` detect an overlapping access across a server's thread pool and
  fail loudly instead of corrupting silently. (fixes #12)
- `run` and `work` are reserved as generated-runtime globals in native
  codegen, so a user function of either name no longer collides.

## [0.7.0] — 2026-08-22

### Fixed

- `fs.readFileSync` no longer aborts uncatchably when a file shrinks
  mid-read. (fixes #25)
- `fs.appendFileSync` uses a real `O_APPEND` instead of
  read-concat-rewrite. (fixes #26)
- `lumen --version` reports the release it was built from instead of the
  hardcoded `0.1.0-dev` every binary had printed since the beginning.
  (fixes #24)

## [0.6.3] — 2026-08-22

### Fixed

- `net.createServer` accepts connections concurrently. (fixes #11)

## [0.6.2] — 2026-08-21

### Fixed

- Two class/type and method/function name-scoping bugs in native codegen.
  (fixes #7, #9)

## [0.6.1] — 2026-08-21

### Fixed

- A thread that registers with the collector unregisters before it exits.
- Assignment through a chained field or index target.
- Documentation no longer claims there is no garbage collector.

## [0.6.0] — 2026-08-20

### Changed

- A URL import becomes a local file before anything reads it, and an import
  URL names a file the compiler reads. (spec 486)

## [0.5.0] — 2026-08-10

### Added

- Decorators, and the request-handling surface built on them: `@Guard` (a
  precondition that runs before a handler and may answer for it), `@From`
  (a named resolver, so derivation stops being copied), `@Valid` (the
  type's own rules, run before the handler), and decorator arguments as
  both values and text. (specs 477, 482–485)
- A module can export a class. (spec 482)
- Handler parameters are bound from the request. (spec 485)
- An optional field may be absent rather than merely null.

### Fixed

- A failed `JSON.parse` names the field that failed. (spec 483)
- Two modules may export the same name, and a file may not both import and
  declare one name. (spec 476)

## [0.4.0] — 2026-08-01

### Added

- A controller is handed to the server whole. (specs 477, 478)

## [0.3.2] — 2026-07-03

### Added

- TypeScript syntax completion (spec 052): the full compound-assignment
  set, labeled statements with labeled `break`/`continue`, `export … from`
  re-exports, `for…in`, ECMAScript `#private` class fields, optional
  chaining on an index (`a?.[i]`), `readonly` arrays, object shorthand and
  computed keys, optional catch binding, and `satisfies`.
- `JSON.stringify` and `JSON.parse<T>`. (spec 051)
- `process.uptime`/`hrtime`/`memoryUsage`/`kill`/`umask`/`getuid`-family/
  `abort`/`version`. (spec 050)
- `console.warn`/`info`/`debug`/`trace`. (spec 048)
- `http.METHODS`/`STATUS_CODES`, and a concurrent `http.createServer`.
  (spec 049)
- Async `fs` beyond the `readFile`/`writeFile`/`appendFile` trio, on a real
  thread pool. (spec 047)
- File-backed streams. (spec 046)

### Fixed

- Bare integer literals no longer coerce to `i64`/`f64` in declarations or
  comparisons.
- A stdout/stderr routing bug in `console`, found while adding the new
  levels.

## [0.3.1] — 2026-07-02

### Fixed

- `lumen watch` failed to cross-compile for Windows.

## [0.3.0] — 2026-07-02

### Added

- The `http` module: client (spec 042 phase 1), then server with keep-alive
  (phase 2).
- `EventEmitter<T>`. (spec 043)
- `fs.watch`, the first `fs` addition `EventEmitter` unblocked. (spec 044)
- Header and querystring support via `Map`. (spec 045)
- `crypto` (`randomBytes`, `randomUUID`, `sha256`), `url` (`parse`,
  `format`), `child_process.spawnSync`, `assert`, `time`, the rest of
  `Math`, and the remaining timers.

### Fixed

- The regex runtime's internal helper names collided with user function
  names.

## [0.2.0] — 2026-07-01

The standard library's first broad pass — `fs`, `path`, `process`, `os` and
the surrounding surface — and the removal of the legacy interpreter
directories.

## [0.1.0] — 2026-06-28

The TypeScript-syntax-to-native pipeline: lexer, parser, type checker,
optimizer, Zig emitter and the `zig build-exe` driver, with classes,
generics, `async`/`await`, error handling, FFI and URL imports.

## [0.0.1] — 2026-06-27

First tagged build.

[Unreleased]: https://github.com/lumen-lang-org/lumen/compare/v0.7.6...HEAD
[0.7.6]: https://github.com/lumen-lang-org/lumen/compare/v0.7.5...v0.7.6
[0.7.5]: https://github.com/lumen-lang-org/lumen/compare/v0.7.4...v0.7.5
[0.7.4]: https://github.com/lumen-lang-org/lumen/compare/v0.7.3...v0.7.4
[0.7.3]: https://github.com/lumen-lang-org/lumen/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/lumen-lang-org/lumen/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/lumen-lang-org/lumen/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/lumen-lang-org/lumen/compare/v0.6.3...v0.7.0
[0.6.3]: https://github.com/lumen-lang-org/lumen/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/lumen-lang-org/lumen/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/lumen-lang-org/lumen/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/lumen-lang-org/lumen/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/lumen-lang-org/lumen/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/lumen-lang-org/lumen/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/lumen-lang-org/lumen/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/lumen-lang-org/lumen/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/lumen-lang-org/lumen/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/lumen-lang-org/lumen/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lumen-lang-org/lumen/compare/v0.0.1...v0.1.0
[0.0.1]: https://github.com/lumen-lang-org/lumen/releases/tag/v0.0.1
