#!/usr/bin/env python3
"""Stamp the stylesheet and script links with a content hash.

    python3 website/stamp.py [--check]

Cloudflare Pages serves style.css and *.js with a five-minute cache, so after
a deploy a browser can pair fresh HTML with a stale stylesheet (a nav button
with no styling, headings under the sticky bar). Every page therefore links
`style.css?v=<hash>` and the like; a change to the file changes the hash and
the browser fetches the new one. Run this after editing style.css, site.js or
highlight.js, before committing. `--check` exits non-zero if any page is out
of date, which is what CI runs.
"""
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ASSETS = ["style.css", "site.js", "highlight.js"]
CHECK = "--check" in sys.argv[1:]

hashes = {a: hashlib.sha1((HERE / a).read_bytes()).hexdigest()[:8] for a in ASSETS}
pattern = re.compile(r'((?:href|src)="/?)(' + "|".join(re.escape(a) for a in ASSETS) + r')(\?v=[0-9a-f]+)?"')

def stamp(text: str) -> str:
    return pattern.sub(lambda m: f'{m.group(1)}{m.group(2)}?v={hashes[m.group(2)]}"', text)

stale = []
for path in sorted([*HERE.glob("*.html"), *HERE.glob("packages/*.html"), *HERE.glob("stdlib/*.html"),
                    HERE / "genpages.py", HERE / "genstdlib.py"]):
    old = path.read_text()
    new = stamp(old)
    if new == old:
        continue
    if CHECK:
        stale.append(str(path.relative_to(HERE.parent)))
    else:
        path.write_text(new)
        print("stamped", path.relative_to(HERE.parent))

if CHECK and stale:
    print("stale asset stamps, run website/stamp.py:\n  " + "\n  ".join(stale))
    raise SystemExit(1)
print("assets:", ", ".join(f"{a}?v={h}" for a, h in hashes.items()))
