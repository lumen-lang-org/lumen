#!/usr/bin/env python3
"""Warm the playground's compile-result cache after a deploy.

server.zig caches compiled wasm by exact source-body match, but the cache is
in-memory and empty on every fresh process. Most visits load one of
play.html's prefilled examples and click Run without editing -- so without
warming, the first user to try each example after a redeploy eats a full
compile. This extracts every example straight from play.html (mirroring its
own frontend extraction: strip at most one leading/trailing newline) and
POSTs each one to /compile, so they're cached before real traffic arrives.

Usage: python3 warm_cache.py [playground_url] [path_to_play_html]
Defaults: http://127.0.0.1:8080  ../website/play.html (relative to this file)
"""

import os
import re
import sys
import urllib.request

EXAMPLE_RE = re.compile(
    r'<script type="text/x-lumen" data-title="[^"]*">(.*?)</script>',
    re.DOTALL,
)


def extract_examples(html: str) -> list[str]:
    examples = []
    for src in EXAMPLE_RE.findall(html):
        src = re.sub(r"^\n", "", src)
        src = re.sub(r"\n$", "", src)
        src = (
            src.replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", '"')
            .replace("&#39;", "'")
        )
        examples.append(src)
    return examples


def main() -> int:
    base_url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
    default_html_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "website", "play.html"
    )
    html_path = sys.argv[2] if len(sys.argv) > 2 else default_html_path

    with open(html_path) as f:
        html = f.read()
    examples = extract_examples(html)
    if not examples:
        print(f"warm_cache: found 0 examples in {html_path} -- nothing to do", file=sys.stderr)
        return 1

    ok = 0
    for i, src in enumerate(examples):
        req = urllib.request.Request(
            f"{base_url}/compile", data=src.encode("utf-8"), method="POST"
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                status = resp.status
        except urllib.error.HTTPError as e:
            status = e.code
        except Exception as e:
            print(f"warm_cache: example {i} request failed: {e}", file=sys.stderr)
            continue
        print(f"warm_cache: example {i} -> HTTP {status}", file=sys.stderr)
        if status == 200:
            ok += 1

    print(f"warm_cache: warmed {ok}/{len(examples)} examples", file=sys.stderr)
    return 0 if ok == len(examples) else 1


if __name__ == "__main__":
    sys.exit(main())
