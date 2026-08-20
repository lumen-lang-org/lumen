# Spec 486: an import URL names a file, and a file is what the compiler reads

## What is true today

A package is meant to be imported by its URL:

```ts
import greet from "https://lumen-lang.org/package/std-contrib/hello/hello.ts";
```

`fetchUrl` (src/lumen.zig:494) goes to the network on every compile, and
fourteen places in the same file ask whether a specifier starts with `https://`
and take a different path when it does: resolution (282, 399), re-export walking
(434, 1397), the decorator check (943), path display (1127, 1883), graph walking
(1335, 1489), emit (2333), the entry read (2501). A URL is not a way of naming a
module. It is a second kind of module, and the difference is threaded through
the whole front end.

Two things fall out of that, and they are the same missing piece.

**The dev loop.** Someone editing `agents` and `plume` on one branch, with
`agents` importing `plume` by URL, compiles against the *published* plume. The
edit in front of them is invisible, and no message says so, the build succeeds,
against the wrong bytes. A build also fails when the network does, and CI pays
that on every run.

**Decorators cannot use the form at all.** Line 944:

```
'@validated' comes from https://lumen-lang.org/package/std-contrib/validation/
validation.ts: a decorator is compiled and run from a local file, so it cannot
be fetched over https [E_DECORATOR]
```

That is correct as the compiler stands, a decorator is compiled and executed,
not inlined, but it makes the documented style unavailable to any package that
exposes decorators. `validation` is one, so every DTO in `agents` reaches for a
five-deep relative path instead of the form the docs teach.

## What other toolchains decided

**Deno** made URL imports the native form and cached them per user in `DENO_DIR`,
keyed by URL, with `--reload` to refetch. The part worth taking is the one it
got right first: **a fetched module becomes an ordinary module the moment it is
on disk.** Nothing downstream of the cache knows a URL was involved. `deno info`
prints the resolved graph, which is the whole of its answer to "which copy did
this build use".

What it had to add later matters just as much. Bare URLs alone made the dev loop
hard enough that Deno shipped import maps, and then `patch`, to let a local
checkout stand in for a published one. The override was not a detail; it was the
missing half.

**Go** answered the same question twice. `replace` in `go.mod` came first and is
a known hazard: it is a line a person writes, and a stale one shipping to a
consumer builds something the consumer cannot reproduce. Workspaces came second
and are the better shape, `go work use ./plume` makes the local checkout win
for every module at once, without editing any module's own file. Its remaining
flaw is that `go.work` is still a file you must remember to create and remove.

**npm link and pnpm workspaces** derive the same thing from the filesystem: a
package that is present is a package that is used. No file to write, no file to
forget.

Deno's cache and its inspectability, Go's workspace semantics, npm's derivation
from disk. None of the three needs a version number to do any of it.

## What this adds

**A resolve phase that runs before the compile, and produces local files.** The
compiler then does what it already does well, on paths it already understands.

For each `https://` specifier, in order:

1. **An open package wins.** Scan the filesystem for packages: the `packages/`
   entries of the repo being compiled, and those of sibling checkouts beside its
   root. Each directory name is a package name. If a segment of the URL path
   matches an open package `N` at local path `L`, and the remainder of the path
   exists under `L`, that file is the resolution.
2. **Otherwise the kept copy wins.** `.lumen-packages/<host>/<path>`, beside the
   entry, laid out by URL.
3. **Otherwise fetch it, write it there, and use it.**

A relative import inside a fetched file is joined against its URL (`joinUrl`,
src/lumen.zig:453) and then goes through the same three steps. That is what
makes the fetch per file rather than per repo: the resolver follows the import
graph and asks only for the modules actually imported, so a URL with no
repository behind it, one file on someone's own server, works exactly as well
as one with a whole project behind it. A cooperating host may offer a bundle as
an optimisation. Never as the mechanism, or single-file hosting stops working.

Having a package open on disk is the entire declaration. There is no file to
write, and none to forget to remove.

### What this does and does not delete

A specifier still has to be recognised as a URL in several places — to decide
that it needs resolving at all, to key module identity, to label a path in a
diagnostic. That recognition does not go away, and does not need to: it is one
`startsWith(spec, "https://")`, not a fork into separate fetch-vs-local logic.

What does go away is the fork. Before this, a URL specifier meant a different
code path from opening the file to running the decorator check. After it,
`appendExpandedSource` resolves a URL to a local path *before* anything else
looks at it, and everything downstream — module identity, cycle detection,
decorators — reads that local path exactly as it would read one written by
hand. A decorator arriving this way is an ordinary local module, so the
refusal at line 944 is deleted, not relaxed, and replaced by whatever
resolution itself failed with. Anything linked into the binary, shims
included, comes from the same prepared tree.

The check that this spec was implemented and not merely added to: `fetchUrl`
is called from exactly one place, the resolver, and nowhere else in the
compiler reads network bytes.

### Where copies live

`.lumen-packages/`, beside the entry, gitignored, the same shape as the
existing `.lumen-libxev-<commit>` (src/lumen.zig:1817), which already
establishes that a fetched dependency is cached in the project rather than in
the home directory. Per project, so a build reads only what is in the project
and `rm -rf .lumen-packages` is a clean slate. A shared store under `$HOME` can
come later purely as a fetch accelerator; the semantics stay per project, so one
project's cache never decides another project's build.

### Saying what happened

```
LUMEN_EXPLAIN_IMPORTS=1    Print every URL in the graph and where it was
                           resolved from: a local checkout and its path, the
                           kept copy, or a fetch. Once per URL, not once per
                           importer.
LUMEN_NO_LOCAL=1           Resolve nothing against open checkouts. Fetch, or
                           use kept copies. What CI sets.
```

Environment rather than flags because both of these are properties of the
*environment a build runs in* — CI sets one for every invocation, a person
exports the other while chasing a resolution — and neither is a decision made
per command. Discarding kept copies is `rm -rf .lumen-packages`, which is
already exactly what a refetch means and needs no flag to say it.

## The rules

1. **The compiler compiles local files.** Resolution finishes before the front
   end starts. No pass downstream of the resolver may reach the network, and
   none of them may branch on a specifier being a URL.
2. **An open package beats a kept copy, which beats the network.** In that
   order, every time, with no flag needed to get the local one, because the
   case this exists for is someone editing two packages at once, and a step they
   have to remember is a step they will forget.
3. **Ambiguity is an error, never a silent pick.** Two open checkouts providing
   `plume`, or one URL whose segments match two different open packages, is a
   refusal that names both paths and stops.
4. **`--no-local` is what CI runs.** A build that resolves nothing locally is the
   one a consumer gets. Without CI building that graph, a developer's build
   stops matching a consumer's and nothing catches it.
5. **Every resolution is inspectable.** "Which copy of plume did this build use"
   has an answer the compiler prints, for every module, without a rebuild.
6. **A fetch failure names the URL and the reason**, not a missing-file error
   about a path under `.lumen-packages` that nobody wrote.
7. **The kept copy is a cache, not a store.** Deleting `.lumen-packages` changes
   nothing except how long the next build takes. Nothing may live there that
   cannot be fetched again.

## Deliberately not in scope

**Versions, tags and a lockfile.** Fetch what the URL returns, keep it, and
refetch only when asked. That is enough to fix the dev loop and lift the
decorator restriction, which is what this spec is for. A tag would also be the
wrong unit: a repository tag covers a whole standard library, not the one
package someone is importing, and requiring one breaks single-file hosting, the
case the per-file fetch exists to protect.

The consequence, recorded so that it is a choice and not a surprise: with no
recorded hash, a remote file that changes underneath an existing kept copy is
invisible, and two machines fetching at different times can build different
bytes from the same source. When that starts to matter the answer is a
*generated* record of URL to content hash, written by the resolver, not a
manifest anyone maintains by hand. Not now.

Found while adding a DTO to `agents`: the review asked for the URL form, and the
compiler refused it. Issue #1.
