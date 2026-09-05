#!/bin/sh
# Emits the generated Zig for every specs/*/examples/valid program into a
# directory, without building any of it, so two runs can be diffed
# (spec 504 FR-003: the native emitter is unchanged by the node backend).
#
#   sh tools/emit_snapshot.sh <out-dir> [lumen-binary]
#
# One file per program: <out-dir>/<spec>/<stem>.zig, or <stem>.err holding
# the compiler's stderr when the program does not compile (a program that
# needs the network, a decorator build, or a C library still snapshots its
# failure the same way on both runs). Compare two snapshots with
#   diff -r <before> <after>
# An empty diff is the gate. The compiler writes the file itself when
# LUMEN_EMIT_ZIG names a directory (see compileFile in src/lumen.zig).
set -u
out=${1:?usage: sh tools/emit_snapshot.sh <out-dir> [lumen-binary]}
lumen=${2:-zig-out/bin/lumen}
rm -rf "$out"
mkdir -p "$out"
count=0
for spec in specs/*/; do
  name=$(basename "$spec")
  for src in "$spec"examples/valid/*.ts; do
    [ -e "$src" ] || continue
    stem=$(basename "$src" .ts)
    mkdir -p "$out/$name"
    if LUMEN_EMIT_ZIG="$out/$name" "$lumen" compile "$src" >/dev/null 2>"$out/$name/$stem.err"; then
      rm -f "$out/$name/$stem.err"
    fi
    count=$((count + 1))
  done
done
echo "snapshot: $count programs -> $out"
