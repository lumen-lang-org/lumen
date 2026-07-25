# Feature Specification: `embed` Is a Reserved Word

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
looked for the `(` that a call would have, did not find one, and fell through
to the diagnostic for a malformed argument — describing a feature the program
was not using.

So the name was already effectively reserved. The behaviour was right and only
the message was wrong, which is the harder kind of bug to see: the rule was
never stated, so a reader looks for a mistake in their own line.

## Decision

`embed` and `embedDir` are reserved words.

They read a file while compiling. A program using one as a variable would read
like an ordinary name and mean something else entirely, and nothing in the
source would tell a reader which. Two words is a small price for that not being
ambiguous.

The alternative — treat the bare word as an ordinary identifier and only the
call form as the feature — was implemented and rejected. It works, but it means
the same word is a compiler feature or a variable depending on the next
character, which is a thing to know rather than a thing to read.

## Scope

In scope:

- `embed` and `embedDir` used as anything but a call are refused, by name.
- The message names the word and says why, rather than describing an argument.
- `obj.embed(x)` and `function embed(...)` are still not the compile-time form
  and are unaffected, as before.

Out of scope:

- Other compiler-owned names. `serve` and `httpGet` defer to a user
  declaration (spec 465) because they are undocumented leftovers, not features
  anyone relies on; these are the opposite.

## Design

The scan already looked for `(` after the word to parse the argument. It now
decides from that: a call is the feature, anything else is the reserved-word
error. One branch, and the diagnostic that used to be reached by accident is
now reached only when there really is a malformed argument.

## Success Criteria

1. `let embed = "x"` reports that `embed` is a reserved word, naming it.
2. `embed("./f.txt")` still embeds.
3. `embed(name)` — a call with a non-literal argument — still reports that the
   path must be a literal, which is now only reachable when it is true.
4. `zig build test` passes; the 458 manifest still passes.

## Notes

Found when a std-contrib test declared `let embed: ModelRow`. The diagnostic
sent the reader looking for a path in a program that had none.
