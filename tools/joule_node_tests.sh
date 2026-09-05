#!/usr/bin/env sh
# Spec 506 T006: sweep a Joule checkout's `*.test.ts` files under both
# `lumen test` targets and print per-file pass/fail parity -- native vs
# `--target node` -- so Joule's spec 004 T005 can record which files already
# match and which don't. A mismatch is not necessarily a Lumen bug: a file
# that reaches a stdlib surface spec 507/508 hasn't given a Node twin yet
# (`// @link-node` naming a `.mjs` that does not exist) fails to *compile*
# under the node target, which this script reports as a `fail`.
#
# Usage: tools/joule_node_tests.sh <joule-dir> [lumen-bin]
set -eu

JOULE_DIR=${1:?usage: tools/joule_node_tests.sh <joule-dir> [lumen-bin]}
LUMEN_BIN=${2:-"$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/lumen"}

[ -x "$LUMEN_BIN" ] || { echo "lumen binary not found or not executable: $LUMEN_BIN" >&2; exit 1; }
[ -d "$JOULE_DIR/src" ] || { echo "no src/ directory under $JOULE_DIR" >&2; exit 1; }

cd "$JOULE_DIR"

results=$(mktemp)
trap 'rm -f "$results"' EXIT

printf '%-70s %-6s %-6s %s\n' "file" "native" "node" "match"

find src -name '*.test.ts' | sort | while IFS= read -r f; do
  # `lumen test`/`lumen test --target node` name their generated artifacts
  # by the source's basename stem in the current directory (spec 504),
  # ignoring its subdirectory -- so cleanup targets live at the repo root,
  # not beside the source file.
  base=$(basename "$f" .ts)
  if "$LUMEN_BIN" test "$f" >/dev/null 2>&1; then native=pass; else native=fail; fi
  rm -f ".lumen-$base.zig" "$base"
  if "$LUMEN_BIN" test --target node "$f" >/dev/null 2>&1; then node=pass; else node=fail; fi
  rm -rf "$base.node"
  match=no
  [ "$native" = "$node" ] && match=yes
  printf '%-70s %-6s %-6s %s\n' "$f" "$native" "$node" "$match"
  echo "$match" >> "$results"
done

total=$(wc -l < "$results")
matched=$(grep -c '^yes$' "$results" || true)
echo
echo "total=$total matched=$matched mismatched=$((total - matched))"
