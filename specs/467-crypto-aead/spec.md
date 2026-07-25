# Feature Specification: Authenticated Symmetric Encryption

## Problem

A std-contrib package stores third-party API keys — Mistral, Anthropic, OpenAI
— in a database. They have to be encrypted at rest, and the language has no
cipher:

```ts
// src/lumen_check_stdlib.zig:203 — the whole of crypto's string surface
crypto.randomBytes(n);
crypto.randomUUID();
crypto.sha256(data);
```

Hashes are one-way, so none of these can give the key back. The package cannot
do its job.

Encrypting outside the language is not the workaround it looks like. It puts
the plaintext key through another process boundary, adds a dependency whose
version nobody tracks, and moves the one part of the program that most needs
reviewing out of the codebase being reviewed.

## Scope

In scope:

```ts
crypto.encrypt(plaintext: string, key: string): string   // base64(nonce ‖ ciphertext ‖ tag)
crypto.decrypt(envelope: string, key: string): string    // plaintext, or "" on any failure
crypto.randomKey(): string                               // 32 random bytes
```

Out of scope:

- Key management: where the master key is stored, how it is rotated, who may
  read it. That is the caller's problem and it is not a language feature.
- Asymmetric encryption, signatures, key exchange.
- Additional authenticated data. The envelope authenticates itself; a caller
  wanting to bind context to it can put that context in the plaintext.
- Streaming encryption of data too large to hold in memory. The values this is
  for are API keys, measured in tens of bytes.

## Design

### D1 — an AEAD, not a plain cipher

AES-256-GCM. The G is the point: alongside the ciphertext it produces an
authentication tag over the whole message, and decryption verifies the tag
before returning anything.

A plain cipher — AES-CTR, AES-CBC — decrypts whatever it is given. Flip a byte
of the stored ciphertext and it produces a different plaintext, with no
indication that anything happened. The caller then sends an attacker-chosen
API key to a provider, or writes attacker-chosen bytes into a config. With
CTR-mode stream ciphers the attacker does not even need to guess: flipping bit
*n* of the ciphertext flips bit *n* of the plaintext, so anyone who knows the
shape of the stored value can rewrite it to a value of their choosing without
ever holding the key.

Under an AEAD that attack fails. A modified envelope produces no plaintext at
all. Detecting tampering — not merely hiding the value — is the reason for the
choice, and it is why the API returns `""` rather than a best-effort decryption.

Zig's standard library provides `std.crypto.aead.aes_gcm.Aes256Gcm`, so this
adds no dependency and no hand-written cryptography.

### D2 — a fresh nonce for every call

GCM takes a 12-byte nonce. It must be unique for every message encrypted under
a given key, and this implementation takes fresh bytes from the same entropy
source `randomBytes` uses on every single call. It is never derived from the
plaintext and never stored for reuse.

Nonce reuse is not a degradation, it is a collapse. Two messages encrypted
under one key with one nonce use the same keystream, so their XOR is the XOR of
the plaintexts; worse, the repetition leaks GHASH's authentication subkey,
which lets an attacker forge tags for that key from then on. A cipher with a
hardcoded nonce still round-trips perfectly in a test, which is why the
conformance case asserts the property directly: the same plaintext encrypted
twice must give two different envelopes.

The nonce is not secret, only unique, so it travels in the clear at the front
of the envelope.

### D3 — the envelope is base64

`base64(nonce ‖ ciphertext ‖ tag)` — 12 bytes, then the ciphertext, then 16.

The output has to land in a database text column, a JSON document, and an HTTP
header, and raw ciphertext is arbitrary bytes including NULs. Returning raw
bytes would mean every caller reaches for an encoding step, and the ones that
forget would find out from a truncated column rather than an error. Encoding
once, here, is the smaller surface.

Both fixed-length parts sit at known offsets, so decrypt splits the envelope
without a length prefix or a format version.

### D4 — decrypt is silent about which check failed

`decrypt` returns `""` for a wrong key, a truncated envelope, an altered
ciphertext, input that is not base64, and an envelope too short to hold a nonce
and a tag. It does not throw and it does not say which.

Which check failed is exactly what an attacker submitting modified envelopes is
trying to learn. An error that distinguishes "not valid base64" from
"authentication failed" from "wrong key" turns the function into an oracle: the
attacker learns how far each probe got, and the differences add up. This is the
same reasoning that makes padding-oracle attacks work against CBC — the
plaintext is recovered from nothing but which error came back.

Throwing has the same problem in a louder form, since an uncaught error also
reports a source location. And a caller who does need to react has all they can
safely act on: the envelope did not open.

One consequence is honest and worth stating: an empty plaintext encrypts to a
valid envelope that decrypts back to `""`, indistinguishable from failure. For
the values this is for — API keys, which are never empty — that is not a
distinction anyone needs.

### D5 — a wrong-length key is refused, at compile time when it can be

The key is exactly 32 bytes, AES-256's key length. Anything else is rejected.

Truncating a long key or zero-padding a short one is the tempting alternative
and the dangerous one: it keeps working, encrypting under a key nobody chose,
with as little real entropy as the caller supplied. A 12-character password
padded to 32 bytes is a 12-character password. Nothing about the program's
behaviour would reveal it.

Two checks, because a key arrives two ways:

- A **string literal** at the call site is measured while compiling and, if it
  is not 32 bytes, is a compile error naming both lengths and pointing at
  `crypto.randomKey()`. The checker decodes the literal's escapes exactly as
  the emitter does, so it measures the bytes the program will actually hold.
- Anything else — an environment variable, a database column, a function
  result — is checked when the call runs, and a wrong length aborts with
  `crypto key must be exactly 32 bytes` at the call site.

The run-time check is the one that matters in practice, since a real master key
is never a literal; the compile-time one costs two lines and catches the
placeholder someone left in while wiring things up.

This is the one failure `decrypt` is loud about, and D4's reasoning is why it
can be. Key length is the operator's own configuration, not attacker-supplied
input — an attacker cannot probe it, and cannot learn anything from a program
that refuses to start.

## Success Criteria

1. A round trip returns the original string exactly, for ASCII, UTF-8
   (`"clé 🔑"`), a string containing a newline, and `""`.
2. The same plaintext encrypted twice under the same key gives two different
   envelopes, and both decrypt correctly.
3. Decrypting with a different key returns `""`.
4. Changing one character of an envelope makes it return `""`, while the
   unmodified envelope still opens.
5. A truncated envelope, an empty string, non-base64 input, and base64 too
   short to be an envelope each return `""` without crashing.
6. A string-literal key that is not 32 bytes fails to compile; a non-literal
   one aborts at the call site.
7. `crypto.randomKey()` returns 32 bytes, differing between calls, usable as a
   key.
8. `zig build test` passes; the 467 manifest passes and 455 is unaffected.

## Notes

The Buffer-facing `crypto.encryptSync(key, iv, data)` from spec 057 already
wraps the same AES-256-GCM primitive, and is left alone. It is the lower-level
shape: the caller supplies the nonce, owns the framing, and gets a Buffer back.
That is the right surface for someone implementing a protocol and the wrong one
for someone storing an API key, because it asks them to generate a unique nonce
themselves — the requirement D2 exists to take away.
