#!/usr/bin/env python3
"""Generate one website page per std-contrib package from its README.

    python3 website/genpages.py [path-to-std-contrib/packages]

Output goes to website/packages/<name>.html. Run it when a README changes;
the pages are committed, so the site still has no build step.

The READMEs use a known subset: ATX headings, tables, fenced code, unordered
lists, paragraphs, inline bold/italic/code/links. Nothing else appears in any
of them (checked), so nothing else is handled.
"""
import html
import re
import sys
from pathlib import Path

# The std-contrib checkout to read READMEs from: first argument, or a sibling
# checkout of this repository.
HERE = Path(__file__).resolve().parent
PKGS = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent.parent / "std-contrib" / "packages"

GROUPS = [
    ("Formats", ["csv", "toml", "dotenv", "semver", "markdown", "pdf"]),
    ("Data", ["plume", "sqlite", "pgvector"]),
    ("Servers", ["rest", "websocket", "socketio", "sse", "press", "validation"]),
    ("AI & agents", ["ai", "agents", "tracing"]),
    ("Tooling", ["token-gate", "code-index", "args", "quickjs"]),
    ("Small & example", ["mathx", "geo", "hello", "greeter"]),
]


def sidebar(current: str) -> str:
    out = []
    for title, names in GROUPS:
        out.append(f'    <p class="docs-nav-title">{title}</p>')
        for n in names:
            cls = ' class="active"' if n == current else ""
            out.append(f'    <a href="/packages/{n}"{cls}>{n}</a>')
    return "\n".join(out)
OUT = HERE / "packages"

SHELL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>{name} · Packages · Lumen</title>
<meta name="description" content="{desc}">
<link rel="stylesheet" href="/style.css">
<link rel="canonical" href="https://lumen-lang.org/packages/{name}">
<meta property="og:url" content="https://lumen-lang.org/packages/{name}">
<meta property="og:title" content="{name} · Packages · Lumen">
<meta property="og:description" content="{desc}">
<meta name="twitter:title" content="{name} · Packages · Lumen">
<meta name="twitter:description" content="{desc}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta name="theme-color" content="#ea580c">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Lumen">
<meta property="og:image" content="https://lumen-lang.org/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
</head>
<body>

<nav><div class="wrap">
  <a class="brand" href="/">Lumen<span class="dot">.</span></a>
  <input type="checkbox" id="nav" class="nav-toggle" hidden>
  <label for="nav" class="nav-burger" aria-label="Menu"></label>
  <span class="links">
    <a href="/#features">Features</a>
    <a href="/examples">Examples</a>
    <a href="/play">Playground</a>
    <a href="/stdlib">Stdlib</a>
    <a href="/packages">Packages</a>
    <a href="/#quickstart">Install</a>
    <a href="https://github.com/lumen-lang-org/lumen">GitHub</a>
  </span>
</div></nav>

<section class="wrap">
  <div class="docs">
  <button type="button" class="docs-nav-toggle" id="docs-nav-toggle" aria-expanded="false" aria-controls="docs-nav">
    <span id="docs-nav-toggle-label">{name}</span>
    <svg width="11" height="7" viewBox="0 0 11 7" fill="none" aria-hidden="true"><path d="M1 1l4.5 4.5L10 1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
  </button>
  <aside class="docs-nav" id="docs-nav"><nav>
    <p class="docs-nav-title"><a href="/packages">All packages</a></p>
{sidebar}
  </nav></aside>
  <div class="docs-main">
  <p class="sub"><a href="/packages">Packages</a> / <strong>{name}</strong>
  · <a href="https://github.com/lumen-lang-org/std-contrib/tree/main/packages/{name}">source</a></p>
{body}
  </div>
  </div>
</section>

<footer><div class="wrap">
  <a href="/packages">← All packages</a> · <a href="/stdlib">Standard library</a>
</div></footer>

<script src="/highlight.js"></script>
<script>
// Mobile package-list toggle: shows/hides the same sidebar nav used on
// desktop. Closes on link click or an outside click. Same code as stdlib.
(function () {{
  var toggle = document.getElementById('docs-nav-toggle');
  var panel = document.getElementById('docs-nav');
  if (!toggle || !panel) return;
  function setOpen(open) {{
    panel.classList.toggle('open', open);
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  }}
  toggle.addEventListener('click', function (e) {{
    e.stopPropagation();
    setOpen(!panel.classList.contains('open'));
  }});
  panel.addEventListener('click', function (e) {{
    if (e.target.tagName === 'A') setOpen(false);
  }});
  document.addEventListener('click', function (e) {{
    if (!panel.contains(e.target) && e.target !== toggle) setOpen(false);
  }});
}})();
</script>
</body>
</html>
"""


def linkTarget(url: str, name: str) -> str:
    """Where a README's relative link should point from the website."""
    if url.startswith(("http://", "https://", "#", "/")):
        return url
    # ../<other-package> is a cross-reference within the catalog
    m = re.match(r"^\.\./([a-z0-9-]+)/?$", url)
    if m:
        return f"/packages/{m.group(1)}"
    # anything else is a file or directory in this package's source
    return f"https://github.com/lumen-lang-org/std-contrib/tree/main/packages/{name}/{url}"


def inline(text: str, name: str) -> str:
    """Inline markdown on already-escaped text."""
    # Code spans are lifted out first so nothing inside one is styled or
    # linkified — `[text](url)` in a syntax listing must stay literal.
    spans = []
    def lift(m):
        spans.append(m.group(1))
        return f"\x00{len(spans) - 1}\x00"
    text = re.sub(r"`([^`]+)`", lift, text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*([^*]+)\*(?![*\w])", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)",
                  lambda m: f'<a href="{linkTarget(m.group(2), name)}">{m.group(1)}</a>', text)
    return re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{spans[int(m.group(1))]}</code>", text)


def render(md: str, name: str):
    lines = md.split("\n")
    out = []
    i = 0
    first_para = ""
    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            lang = line[3:].strip()
            block = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                block.append(lines[i])
                i += 1
            i += 1  # closing fence
            code = html.escape("\n".join(block), quote=False)
            cls = ' class="lumen"' if lang in ("ts", "lumen", "") else ""
            out.append(f"<pre><code{cls}>{code}</code></pre>")
            continue

        m = re.match(r"^(#{1,6}) (.*)$", line)
        if m:
            depth = len(m.group(1))
            text = inline(html.escape(m.group(2), quote=False), name)
            if depth == 1:
                out.append(f"  <h2>{text}</h2>")
            else:
                # h2 in the README is a section: h3 on the page, one level
                # under the package name.
                out.append(f"  <h{depth + 1}>{text}</h{depth + 1}>")
            i += 1
            continue

        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(lines[i])
                i += 1
            out.append("  <table>")
            for r, row in enumerate(rows):
                if re.match(r"^\|[\s\-:|]+\|$", row):
                    continue  # the separator row
                cells = [c.strip() for c in row.strip().strip("|").split("|")]
                tag = "th" if r == 0 else "td"
                cells = [inline(html.escape(c, quote=False), name) for c in cells]
                out.append("    <tr>" + "".join(f"<{tag}>{c}</{tag}>" for c in cells) + "</tr>")
            out.append("  </table>")
            continue

        if line.startswith("- "):
            out.append("  <ul>")
            nested = False
            while i < len(lines) and (lines[i].startswith("- ") or lines[i].startswith("  ")):
                if lines[i].startswith("  - "):
                    # one level of nesting, which is all any README uses
                    if not nested:
                        out[-1] = out[-1][:-5] + "<ul>"
                        nested = True
                    out.append("      <li>" + inline(html.escape(lines[i][4:], quote=False), name) + "</li>")
                    i += 1
                    continue
                if nested:
                    out.append("    </ul></li>")
                    nested = False
                if lines[i].startswith("- "):
                    out.append("    <li>" + inline(html.escape(lines[i][2:], quote=False), name) + "</li>")
                else:
                    # a continuation line of the previous item
                    out[-1] = out[-1][:-5] + " " + inline(html.escape(lines[i].strip(), quote=False), name) + "</li>"
                i += 1
            if nested:
                out.append("    </ul></li>")
            out.append("  </ul>")
            continue

        if line.strip() == "":
            i += 1
            continue

        # a paragraph: gather until a blank or a block opener
        para = []
        while i < len(lines) and lines[i].strip() != "" and not re.match(r"^(#|```|\||- )", lines[i]):
            para.append(lines[i].strip())
            i += 1
        text = inline(html.escape(" ".join(para), quote=False), name)
        if not first_para:
            first_para = re.sub(r"<[^>]+>", "", text)
        out.append(f'  <p class="sub">{text}</p>')

    return "\n".join(out), first_para


def main():
    OUT.mkdir(exist_ok=True)
    written = []
    for pkg in sorted(PKGS.iterdir()):
        readme = pkg / "README.md"
        if not readme.exists():
            continue
        name = pkg.name
        body, desc = render(readme.read_text(), name)
        desc = html.escape(desc.replace("\n", " ").strip(), quote=True)
        if len(desc) > 155:
            desc = desc[:152].rsplit(" ", 1)[0] + "…"
        page = SHELL.format(name=name, desc=desc, body=body, sidebar=sidebar(name))
        (OUT / f"{name}.html").write_text(page)
        written.append(name)
    print(f"{len(written)} pages: {', '.join(written)}")


if __name__ == "__main__":
    main()
