# Feature Specification: `embed` Is Not a Reserved Word

## Problem

A variable named `embed` was refused, with a message about something else:

```ts
function main(): void {
  let embed = "not a builtin";
  console.log(embed);
}
```

```
emb.ts:2:7: error: the path must be a literal — the file is read while
            compiling, so there is nothing to evaluate [E_EMBED]
```

There is no path in that program. The scanner (spec 458) recognised the word,
looked for the `(` a call would have, did not find one, and fell through to the
diagnostic for a malformed argument — describing a feature the program was not
using.

So the name was effectively reserved without ever being declared so. That is
the harder kind of bug to see: the rule was never stated, so a reader looks for
a mistake in their own line.

## Decision

`embed` and `embedDir` are **not** reserved words.

Only a call is the compile-time form. `let embed = "x"` declares a variable and
`stringify(embed)` reads one; neither reads a file, so neither is this
feature's business. Both forms may appear in one program:

```ts
let embed = "a variable";
const text: string = embed("./f.txt");
// a variable | hello from a file
```

A package should not have to know which names the compiler has taken. That is
the same fault as a parameter colliding with a function from another module
(spec 461), seen from the compiler's side rather than the program's — and it
was decided the same way there.

Reserving the words was implemented first and reversed. It works, and the
argument for it is real: the same word being a compiler feature or a variable
depending on the next character is a thing to know rather than a thing to read.
It was not worth taking two ordinary words from every program to get it.

## Scope

In scope:

- `embed` and `embedDir` followed by `(` are the compile-time form.
- Anywhere else they are ordinary identifiers.
- `embed(name)` with a non-literal argument still reports that the path must
  be a literal — a diagnostic now reachable only when it is true.

Out of scope:

- Whether a program *should* name something `embed`. It reads poorly next to
  the feature, and that is the author's business rather than the compiler's.

## Design

The scan already looked for `(` to parse the argument. It now decides from
that: a call is substituted, anything else is copied through untouched. One
branch, and the argument diagnostic stops being reachable by accident.

## Success Criteria

1. `let embed = "x"` compiles and the variable behaves like any other.
2. `embed("./f.txt")` still embeds.
3. Both in one program, each meaning what it says.
4. `embed(name)` still reports that the path must be a literal.
5. `zig build test` passes; the 458 manifest still passes.

## Notes

Found when a std-contrib test declared `let embed: ModelRow`. The diagnostic
sent the reader looking for a path in a program that had none — which was worth
fixing whichever way the naming question went.
