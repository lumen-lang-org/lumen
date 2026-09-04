# Releasing Lumen

## The version scheme

Lumen is pre-1.0, and uses [Semantic Versioning](https://semver.org/) under
the reading that section 4 allows for a `0.y.z` major version:

| Bump | When | Promise |
| --- | --- | --- |
| `0.7.6 → 0.7.7` | a stdlib addition, a compiler fix, a diagnostic, docs | a program that compiled before still compiles |
| `0.7.6 → 0.8.0` | a removal, a rename, a semantic change, a CLI flag dropped | may break a program that compiled before |
| `0.x → 1.0.0` | the language is committed to | not yet |

The distinction that matters day to day: **adding** to the standard library
is a patch bump, because nothing that compiled stops compiling. Most releases
here are patch bumps, and that is the intended shape — the 0.7 line ran from
0.7.0 to 0.7.6 in eleven days.

A release whose diff touches only `website/` does not need a version at all.
The site deploys from the production branch through Cloudflare Pages, on its
own schedule, with no tag involved. Tag when the **compiler** changed.

## Cutting a release

1. **Check what actually changed since the last tag.**

   ```sh
   git fetch --tags origin
   git diff --stat "$(git describe --tags --abbrev=0)"..HEAD
   ```

   If nothing outside `website/` changed, there is no compiler release to
   make. Deploy the site instead.

2. **Write the `CHANGELOG.md` entry.** Move everything under
   `## [Unreleased]` into a new `## [x.y.z] — YYYY-MM-DD` section, add the
   comparison link at the bottom of the file, and leave `[Unreleased]`
   empty above it.

3. **Bump `.version` in `build.zig.zon`** to the same number, without the
   `v`.

4. **Commit both**, then tag:

   ```sh
   git tag -a v0.7.7 -m "Lumen 0.7.7"
   git push origin main
   git push origin v0.7.7
   ```

   The tag must be annotated (`-a`). A lightweight tag carries no tagger,
   date or message, so `git describe` and the release page lose the one
   record of who cut it and when.

5. **Watch the workflow.** Pushing a `v*` tag triggers
   `.github/workflows/release.yml`, which builds five targets in parallel
   on GitHub-hosted runners — `{x86_64,aarch64}-{linux,macos}` and
   `x86_64-windows` — and attaches an archive per target to the GitHub
   Release.

## What the release workflow does that a local build does not

Before compiling, the workflow overwrites `src/lumen_version.zig` with the
tag:

```sh
version="${GITHUB_REF_NAME#v}"
echo "pub const lumen_version = \"$version\";" > src/lumen_version.zig
```

A build from a checkout never gets that overwrite, so it keeps reporting the
`-dev` string committed in the file. That is deliberate and load-bearing: a
release version never contains `dev`, so `lumen version` always distinguishes
a release from a working-tree build. Do not "fix" the committed constant to a
real version — see spec 491, and issue #24, which existed because every
released binary for months reported `0.1.0-dev`.

Each archive is self-contained: the `lumen` binary plus the Zig toolchain it
shells out to, under `./zig`. That is why an archive is ~90 MB.

## After the tag

`install.sh` fetches
`https://github.com/lumen-lang-org/lumen/releases/latest/download/lumen-<target>.tar.gz`,
so the one-line install on the website starts serving the new release as soon
as GitHub marks it latest. Nothing else needs updating.

Check it end to end, on a machine that has no Lumen installed:

```sh
curl -fsSL https://lumen-lang.org/install.sh | sh
~/.lumen/bin/lumen version    # must print the tag, not a -dev string
```
