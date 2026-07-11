# Spec 253: fs.readFileSync / writeFileSync raise catchable errors

## Goal

```ts
try {
  const s: string = fs.readFileSync("missing.txt")
} catch (e) {
  console.log(e.message)   // cannot read 'missing.txt': FileNotFound
}
```

Previously a missing/unreadable file silently read as `""` and a failed
write did nothing — no error, no signal (Node throws ENOENT for both).

## Semantics

In location-tracked builds, `fs.readFileSync` and `fs.writeFileSync` raise a
Lumen exception naming the path and the OS error, flowing through the
spec-245 propagation machinery (catchable, forwardable, pretty uncaught
rendering with position). Happy paths are unchanged. Release-fast builds
keep the old silent fallbacks. Other fs calls (`existsSync` returning bool,
`realpathSync`'s path fallback, etc.) are unchanged; converting the
remaining mutating calls is future work.

## Success Criteria

- **SC-001**: Reading a missing file inside try/catch is caught with the
  path in the message; uncaught reports position + trace context.
- **SC-002**: Writing to an unwritable path raises the same way.
- **SC-003**: A write-read-delete round-trip works as before;
  `zig build` and `zig build test` stay green.
