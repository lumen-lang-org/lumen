# Feature Specification: `String.fromCodePoint` Encodes a Code Point

## Problem

`String.fromCodePoint(233)` produces one byte, `0xE9`. That is not `"é"` — it
is not valid UTF-8 at all, and a string holding it prints as a replacement
character and has length 1 where the language says `"é".length` is 2.

The language has no other way to spell a character by its number, so there is
currently no way to write one. That is how it was found: a JSON reader
resolving `é` in a tool's reply, which is ordinary work, produced text the
user could see was wrong and could not fix.

Spec 119 defined `fromCodePoint` as an alias for `fromCharCode` — "one byte per
code, each masked to `code & 0xFF`" — on the grounds that the language is
byte-oriented. The premise is right and the conclusion does not follow. A
string is a sequence of UTF-8 bytes; a *code point* is a character, and the two
are the same thing only below `0x80`.

## Scope

In scope:

- `String.fromCodePoint(...codes)` encodes each argument as UTF-8.

Out of scope:

- `String.fromCharCode`, which keeps its byte semantics. Its argument is a code
  *unit*, and building a byte at a time is what it is for: `router.ts` in
  std-contrib percent-decodes a URL with it, assembling multi-byte UTF-8 from
  the bytes the encoding actually carries. Changing it would break that, and
  correctly — those bytes are not code points.

That the two names now differ is the point of having two names.

## Design

### D1 — one argument, one character

Each argument is encoded as UTF-8 and the results are concatenated, so
`fromCodePoint(72, 105)` is still `"Hi"` and every existing use below `0x80` is
unchanged.

### D2 — what is not a code point

Surrogates (`0xD800`–`0xDFFF`), negatives, and anything above `0x10FFFF` are
not characters and cannot be encoded. Each is emitted as U+FFFD, the
replacement character, rather than raising: this is a value that arrives from a
document being read, and a malformed escape in someone else's JSON should mark
itself in the text, not stop the program.

A surrogate *pair* is two arguments and produces two replacement characters. A
caller decoding UTF-16 escapes combines the halves before calling this — which
is what `🚀` requires of any reader, and what the JSON scanner in
std-contrib's agents package does.

## Success Criteria

1. `String.fromCodePoint(233)` is `"é"`, two bytes, `.length == 2`.
2. `String.fromCodePoint(128640)` is `"🚀"`, four bytes.
3. `String.fromCodePoint(72, 105)` is `"Hi"` — spec 119's SC-001 unchanged.
4. `String.fromCodePoint(0xD800)` is U+FFFD, not a byte and not a crash.
5. `String.fromCharCode(195) + String.fromCharCode(169)` is still `"é"` — the
   byte-at-a-time path is untouched.
6. `zig build test` and `zig build conformance` add no failures.
7. std-contrib's rest package still decodes percent-encoded UTF-8 paths.

## Notes

Supersedes FR-002 of spec 119 ("Behaves identically to `String.fromCharCode`").
The rest of 119 stands.
