#!/bin/sh
# Idempotent toolchain setup for the Node-target work (specs 501-508), for a
# container that has Node but no Zig. Safe to re-run. Prints the PATH line to
# eval at the end.
#
#   sh tools/node-target-env.sh && export PATH=$HOME/.zig:$PATH
set -e
ZIG_VERSION=0.16.0
ZIG_DIR=${ZIG_DIR:-$HOME/.zig}
XEV_COMMIT=9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf
SCRATCH=${TMPDIR:-/tmp}/lumen-node-target-env
mkdir -p "$SCRATCH"

if ! "$ZIG_DIR/zig" version 2>/dev/null | grep -q "^$ZIG_VERSION"; then
  arch=$(uname -m); os=$(uname -s | tr '[:upper:]' '[:lower:]')
  tar="zig-$arch-$os-$ZIG_VERSION.tar.xz"
  echo "fetching $tar"
  curl -sSf -o "$SCRATCH/$tar" "https://ziglang.org/download/$ZIG_VERSION/$tar"
  rm -rf "$ZIG_DIR"; mkdir -p "$ZIG_DIR"
  tar -xJf "$SCRATCH/$tar" -C "$ZIG_DIR" --strip-components=1
fi
export PATH="$ZIG_DIR:$PATH"
zig version

# libxev: zig's own fetcher cannot always reach GitHub (proxy); a plain git
# clone can. Fetching the clean tree (no .git) yields the manifest's hash.
CACHE=$(zig env | sed -n 's/.*"global_cache_dir": "\(.*\)",/\1/p' | head -1)
[ -n "$CACHE" ] || CACHE=$(zig env | sed -n 's/.*\.global_cache_dir = "\(.*\)",/\1/p' | head -1)
HASH=$(sed -n 's/.*\.hash = "\(libxev-[^"]*\)".*/\1/p' build.zig.zon)
if [ ! -e "$CACHE/p/$HASH" ] && [ ! -e "$CACHE/p/$HASH.tar.gz" ]; then
  rm -rf "$SCRATCH/libxev"
  git clone -q https://github.com/mitchellh/libxev.git "$SCRATCH/libxev"
  (cd "$SCRATCH/libxev" && git checkout -q "$XEV_COMMIT" && rm -rf .git)
  zig fetch "$SCRATCH/libxev" >/dev/null
fi

# The Boehm collector: lumen links `-lgc`, which needs the unversioned .so.
if ! ls /usr/lib/*/libgc.so /usr/local/lib/libgc.so >/dev/null 2>&1; then
  so=$(ls /usr/lib/*/libgc.so.1 /lib/*/libgc.so.1 2>/dev/null | head -1)
  if [ -n "$so" ]; then ln -sf "$so" "$(dirname "$so")/libgc.so"; else
    echo "libgc missing: apt-get install -y libgc-dev (or brew install bdw-gc)"; fi
fi

zig build
./zig-out/bin/lumen version
node --version
echo "export PATH=$ZIG_DIR:\$PATH"
