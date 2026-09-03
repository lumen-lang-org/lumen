#!/usr/bin/env python3
"""Generate one website page per std-contrib package from its README.

    python3 website/genpages.py [path-to-std-contrib/packages] [--check]

Output goes to website/packages/<name>.html, and the catalog table in
packages.html is rewritten from std-contrib's index.json. Run it when a README
changes; the pages are committed, so the site still has no build step.
`--check` writes nothing and exits non-zero if the committed pages are stale,
which is what CI runs.

The READMEs use a known subset: ATX headings, tables, fenced code, unordered
lists, paragraphs, inline bold/italic/code/links. Anything outside it is an
error naming the file and line, rather than a page that silently drops or
mangles the content.

A README section fenced by

    <!-- website:skip -->
    ## Testing
    …
    <!-- /website:skip -->

is for contributors and does not reach the site. That is how `lumen test` runs
and repo-relative build steps stay in the README without appearing on a page
whose reader never cloned the repository.
"""
import html
import json
import re
import sys
from pathlib import Path

# The std-contrib checkout to read READMEs from: first argument, or a sibling
# checkout of this repository.
HERE = Path(__file__).resolve().parent
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
CHECK = "--check" in sys.argv[1:]
PKGS = Path(ARGS[0]) if ARGS else HERE.parent.parent / "std-contrib" / "packages"
# The catalog is the one source of a package's one-line summary: it feeds each
# page's meta description and the table on packages.html, so the two cannot
# disagree.
INDEX = PKGS.parent / "index.json"

GROUPS = [
    ("Formats", ["csv", "toml", "dotenv", "semver", "markdown", "pdf"]),
    ("Data", ["plume", "sqlite", "pgvector"]),
    ("Servers", ["rest", "openapi", "websocket", "socketio", "sse", "press", "validation"]),
    ("AI & agents", ["ai", "agents", "tracing"]),
    ("Tooling", ["token-gate", "code-index", "args", "quickjs", "cron", "tty", "mail"]),
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
<script>try{{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}}catch(e){{}}</script>
<title>{name} · Packages · Lumen</title>
<meta name="description" content="{desc}">
<link rel="stylesheet" href="/style.css?v=268ce722">
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
<a class="skip-link" href="#main">Skip to content</a>

<nav><div class="wrap">
  <a class="brand" href="/">Lumen<span class="dot">.</span></a>
  <input type="checkbox" id="nav" class="nav-toggle" hidden>
  <span class="links">
    <a href="/learn">Learn</a>
    <a href="/examples">Examples</a>
    <a href="/play">Playground</a>
    <a href="/stdlib">Stdlib</a>
    <a href="/packages">Packages</a>
    <a href="/#quickstart">Install</a>
    <a href="https://github.com/lumen-lang-org/lumen">GitHub</a>
  </span>
  <button type="button" class="theme-toggle" aria-label="Switch between light and dark theme" title="Switch theme">
    <svg class="icon-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
    <svg class="icon-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
  </button>
  <label for="nav" class="nav-burger" aria-label="Menu"></label>
</div></nav>

<section class="wrap" id="main">
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
  <span class="brand">Lumen<span class="dot">.</span></span>
  <p>A compiled TypeScript-syntax language.</p>
  <p class="footlinks">
    <a href="/learn">Learn</a> ·
    <a href="/examples">Examples</a> ·
    <a href="/play">Playground</a> ·
    <a href="/stdlib">Standard library</a> ·
    <a href="/packages">Packages</a> ·
    <a href="/roadmap">Roadmap</a> ·
    <a href="/community">Community</a> ·
    <a href="https://github.com/lumen-lang-org/lumen">GitHub</a> ·
    <a href="https://github.com/lumen-lang-org/lumen/releases">Releases</a>
  </p>
</div></footer>

<script src="/highlight.js?v=25b44fe7"></script>
<script src="/site.js?v=3daeecb8"></script>
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


def unhandled(line: str) -> str:
    """Why this line is outside the subset the renderer handles, or ""."""
    if re.match(r"^\s*\d+\. ", line):
        return "an ordered list"
    if line.startswith(">"):
        return "a blockquote"
    if line.startswith("    ") and line.strip():
        return "an indented code block (use a fence)"
    if re.match(r"^(=+|-{2,})\s*$", line):
        return "a setext heading underline (use #)"
    if re.match(r"^\s*!\[", line):
        return "an image"
    if re.match(r"^\s*<(?!!--)", line):
        return "raw HTML"
    return ""


def render(md: str, name: str, where: str = ""):
    lines = md.split("\n")
    out = []
    i = 0
    first_para = ""
    while i < len(lines):
        line = lines[i]

        # A contributor-only section: dropped whole, fence included.
        if line.strip() == "<!-- website:skip -->":
            i += 1
            while i < len(lines) and lines[i].strip() != "<!-- /website:skip -->":
                i += 1
            if i == len(lines):
                raise SystemExit(f"{where}: <!-- website:skip --> is never closed")
            i += 1
            continue

        # Any other comment is a note to a reader of the README, not content.
        if line.strip().startswith("<!--") and line.strip().endswith("-->"):
            i += 1
            continue

        why = unhandled(line)
        if why:
            raise SystemExit(f"{where}:{i + 1}: {why} is not handled: {line.strip()[:60]}")

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
                # The README title is the page title: the one h1 on the page.
                out.append(f"  <h1>{text}</h1>")
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
            # A setext underline reads as prose to the gatherer above, so the
            # heading would silently become a paragraph.
            if re.match(r"^(=+|-{2,})\s*$", lines[i]):
                raise SystemExit(f"{where}:{i + 1}: a setext heading is not handled (use #)")
            para.append(lines[i].strip())
            i += 1
        text = inline(html.escape(" ".join(para), quote=False), name)
        if not first_para:
            first_para = re.sub(r"<[^>]+>", "", text)
        out.append(f'  <p class="sub">{text}</p>')

    return "\n".join(out), first_para


def catalog() -> dict:
    """Each package's one-line summary, from std-contrib's index.json.

    A package with a directory and no entry is an error: the catalog is what
    the site, the root README and the package manager all read, so a package
    missing from it is a package that exists three-quarters of the way.
    """
    entries = json.loads(INDEX.read_text())["packages"]
    summaries = {e["name"]: e["summary"] for e in entries}
    dirs = {p.name for p in PKGS.iterdir() if (p / "README.md").exists()}
    missing = sorted(dirs - set(summaries))
    stale = sorted(set(summaries) - dirs)
    if missing:
        raise SystemExit(f"{INDEX}: no entry for {', '.join(missing)}")
    if stale:
        raise SystemExit(f"{INDEX}: entry for {', '.join(stale)}, which has no package")
    # A package absent from GROUPS renders a page nothing links to, which is
    # the one kind of drift a reader finds before we do.
    grouped = {n for _, names in GROUPS for n in names}
    ungrouped = sorted(set(summaries) - grouped)
    if ungrouped:
        raise SystemExit(f"genpages.py: add {', '.join(ungrouped)} to GROUPS for the sidebar")
    return summaries


GROUP_INTRO = {
    "Formats": "Parse and write text formats.",
    "Data": "Databases and stores, over the C FFI.",
    "Servers": "HTTP servers, sockets, templates and validation.",
    "AI & agents": "Model APIs, agents and traces.",
    "Tooling": "Command lines, terminals, schedules and mail.",
    "Small & example": "Tiny packages that show the import model.",
}


def usesFfi(name: str) -> bool:
    """A package that links a C library: any of its sources carries // @link."""
    return any("@link" in p.read_text() for p in (PKGS / name).glob("*.ts"))


def catalogCards(summaries: dict) -> str:
    """The catalog on packages.html: one card per package, grouped as the
    package pages' sidebar groups them, in that order."""
    out = []
    for title, names in GROUPS:
        gid = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        out.append(f'  <div class="pkg-group" id="{gid}">')
        out.append(f'    <h3>{html.escape(title, quote=False)} <span class="pkg-count">{len(names)}</span></h3>')
        out.append(f'    <p class="sub">{GROUP_INTRO[title]}</p>')
        out.append('    <div class="pkg-grid">')
        for n in names:
            badge = ' <span class="badge badge-ffi" title="Links a C library through the FFI">FFI</span>' if usesFfi(n) else ""
            out.append(f'      <a class="pkg" href="/packages/{n}" data-name="{n}">\n'
                       f'        <span class="pkg-name">{n}{badge}</span>\n'
                       f'        <span class="pkg-summary">{html.escape(summaries[n], quote=False)}</span>\n'
                       f'      </a>')
        out.append("    </div>\n  </div>")
    return "\n".join(out)


def emit(path: Path, text: str, stale: list) -> None:
    """Write, or under --check record that the committed file is out of date."""
    if CHECK:
        if not path.exists() or path.read_text() != text:
            stale.append(str(path.relative_to(HERE.parent)))
        return
    path.write_text(text)


def main():
    summaries = catalog()
    stale = []
    if not CHECK:
        OUT.mkdir(exist_ok=True)
    written = []
    for pkg in sorted(PKGS.iterdir()):
        readme = pkg / "README.md"
        if not readme.exists():
            continue
        name = pkg.name
        body, first = render(readme.read_text(), name, where=str(readme))
        # The catalog's summary is written for this job; the first paragraph is
        # only a fallback for a package the catalog has not reached yet.
        desc = html.escape((summaries.get(name) or first).replace("\n", " ").strip(), quote=True)
        if len(desc) > 155:
            desc = desc[:152].rsplit(" ", 1)[0] + "…"
        page = SHELL.format(name=name, desc=desc, body=body, sidebar=sidebar(name))
        emit(OUT / f"{name}.html", page, stale)
        written.append(name)

    # The catalog table, so packages.html is not a third hand-kept list.
    listing = HERE / "packages.html"
    text = listing.read_text()
    fenced = re.sub(r"(?s)(<!-- catalog:start -->\n).*?(\n\s*<!-- catalog:end -->)",
                    lambda m: m.group(1) + catalogCards(summaries) + m.group(2), text)
    if fenced == text and "<!-- catalog:start -->" not in text:
        raise SystemExit(f"{listing}: no <!-- catalog:start --> … <!-- catalog:end --> region")
    emit(listing, fenced, stale)

    if CHECK:
        if stale:
            print("stale, regenerate with genpages.py:\n  " + "\n  ".join(stale))
            raise SystemExit(1)
        print(f"{len(written)} pages up to date")
        return
    print(f"{len(written)} pages: {', '.join(written)}")


if __name__ == "__main__":
    main()
