# Feature Specification: `crypto.sha1`, and Base64 as a Primitive

## Problem

A WebSocket server cannot be written in this language, and the reason is one
missing hash.

RFC 6455's handshake requires the server to answer a client's key with:

```
Sec-WebSocket-Accept = base64( SHA1( key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )
```

Both the algorithm and the constant are fixed by the specification. A browser
that receives any other value closes the connection, so there is no substitute:
no SHA-1, no WebSocket, and therefore nothing built on one.

`crypto` today offers `randomBytes`, `randomUUID`, `sha256`, `randomKey`,
`encrypt` and `decrypt`. Base64 exists only as hand-written code in
std-contrib's `tracing/backend.ts`, where it was added for a Basic auth header;
a second copy is already wanted here, which is the usual sign that it belongs
one layer down.

## The objection, and why it is overruled

SHA-1 is broken for anything relying on collision resistance, and a language
adding it in 2026 should have to say why.

It is not used here as a signature, a password hash or an integrity check. It
is a fixed token in a handshake — the input is a random key the client just
sent and a constant published in the RFC, and the output is compared for
equality by the peer. Collision resistance is not a property the protocol
depends on.

The alternative is refusing WebSocket support permanently. That is the trade,
and it is worth making with the reason recorded rather than rediscovered.

`crypto.sha1`'s documentation says this in one line, so a reader reaching for
it for the wrong purpose is told at the point of use.

## Scope

In scope:

- `crypto.sha1(data: string): string` — the hex digest, exactly as `sha256`.
- `crypto.base64Encode(data: string): string` and
  `crypto.base64Decode(text: string): string`.

Out of scope:

- SHA-1 over bytes rather than hex out. `sha256` returns hex and these should
  match; the handshake needs the raw digest base64-encoded, so
  `base64Encode` must accept the bytes rather than the hex — see D2.
- Any other legacy hash. MD5 is not needed by anything here.

## Design

### D1 — mirroring `sha256`

Three call sites, all of which `sha256` already occupies: a checker branch in
`cryptoCallType`, an emitter branch in `lumen_emit_static.zig`, and a runtime
helper beside `__cryptoSha256`. Zig's standard library has `Sha1`, so the
helper is four lines.

### D2 — the digest as bytes, not hex

The handshake base64-encodes the *digest*, not its hex spelling. Encoding the
hex gives a 28-character string that is the wrong length and the wrong value,
and a browser refuses it — a mistake that costs an afternoon because both
strings look plausible.

So `crypto.sha1` returns hex like `sha256`, and a second entry point returns
the raw bytes:

- `crypto.sha1Bytes(data: string): string` — the 20 bytes, in a string, the
  way `String.fromCharCode` and this language's byte handling already work.

`base64Encode` takes those bytes. The handshake is then one line, and neither
function has a hex/bytes ambiguity in it.

### D3 — base64 in `crypto`, not `String`

It is not a string operation; it is an encoding used by credentials and
protocols. `crypto` is where the callers already are.

Decoding is included because a WebSocket client must verify the `Accept` it
receives, and a package that can only encode makes that impossible.

## Success Criteria

1. `crypto.sha1("abc")` is `a9993e364706816aba3e25717850c26c9cd0d89d`.
2. `crypto.sha1("")` is `da39a3ee5e6b4b0d3255bfef95601890afd80709`.
3. `crypto.sha1Bytes("abc").length` is 20.
4. `crypto.base64Encode("pk:sk")` is `cGs6c2s=`; `base64Decode` round-trips it.
5. The RFC 6455 example: key `dGhlIHNhbXBsZSBub25jZQ==` yields
   `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
6. `zig build test` passes; the conformance failure set is unchanged.

Every value above is from the specification or another implementation. A test
that hashes a string and compares it to the same call proves nothing — the
base64 test in std-contrib did exactly that this week and would have passed
against a broken encoder.

## Notes

Prerequisite for spec 475 (WebSocket framing) and everything above it.
