#!/usr/bin/env python3
"""Generate one page per standard-library module from stdlib.html.

    python3 website/genstdlib.py [--check]

stdlib.html stays the one place the reference is written: the whole library
on one page, searchable. Each `<h4 id="…">` module section under "Available
now" is also emitted as website/stdlib/<id>.html with its own sidebar, so a
module has a short page and a URL of its own (/stdlib/fs). The generator also
fills two fenced regions from the same split:

    stdlib.html   <!-- modules:start --> … <!-- modules:end -->   the module index
    sitemap.xml   <!-- stdlib:start --> … <!-- stdlib:end -->     one <url> per module

Run it after editing stdlib.html, then website/stamp.py. `--check` writes
nothing and exits non-zero when any output is stale; CI runs it.
"""
import html
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "stdlib.html"
OUT = HERE / "stdlib"
SITEMAP = HERE / "sitemap.xml"
CHECK = "--check" in sys.argv[1:]

SHELL = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<script>try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}</script>
<title>@@TITLE@@ · Standard library · Lumen</title>
<meta name="description" content="@@DESC@@">
<link rel="stylesheet" href="/style.css?v=cc47e897">
<link rel="canonical" href="https://lumen-lang.org/stdlib/@@ID@@">
<meta property="og:url" content="https://lumen-lang.org/stdlib/@@ID@@">
<meta property="og:title" content="@@TITLE@@ · Standard library · Lumen">
<meta property="og:description" content="@@DESC@@">
<meta name="twitter:title" content="@@TITLE@@ · Standard library · Lumen">
<meta name="twitter:description" content="@@DESC@@">
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
    <span id="docs-nav-toggle-label">@@TITLE@@</span>
    <svg width="11" height="7" viewBox="0 0 11 7" fill="none" aria-hidden="true"><path d="M1 1l4.5 4.5L10 1" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
  </button>
  <aside class="docs-nav" id="docs-nav"><nav>
    <p class="docs-nav-title"><a href="/stdlib">All modules</a></p>
    <p class="docs-nav-title">Modules</p>
@@SIDEBAR@@
    <p class="docs-nav-title">More</p>
    <a href="/roadmap">Roadmap</a>
    <a href="/packages">Packages</a>
  </nav></aside>
  <div class="docs-main">
  <p class="sub"><a href="/stdlib">Standard library</a> / <strong>@@TITLE@@</strong>
  · <a href="/stdlib#@@ID@@">on the one-page reference</a></p>
@@BODY@@
  <div class="next">
@@PREVNEXT@@
  </div>
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
// Mobile module-list toggle, as on the other docs pages.
(function () {
  var toggle = document.getElementById('docs-nav-toggle');
  var panel = document.getElementById('docs-nav');
  if (!toggle || !panel) return;
  function setOpen(open) {
    panel.classList.toggle('open', open);
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
  }
  toggle.addEventListener('click', function (e) { e.stopPropagation(); setOpen(!panel.classList.contains('open')); });
  panel.addEventListener('click', function (e) { if (e.target.tagName === 'A') setOpen(false); });
  document.addEventListener('click', function (e) { if (!panel.contains(e.target) && e.target !== toggle) setOpen(false); });
})();
</script>
</body>
</html>
"""

TAG = re.compile(r"<[^>]+>")
ACTIVE = ' class="active"'


def text(fragment: str) -> str:
    """Plain text of an HTML fragment, without any stability/target pills."""
    fragment = re.sub(r'<span class="[^"]*pill[^"]*"[^>]*>.*?</span>', "", fragment, flags=re.S)
    return html.unescape(TAG.sub("", fragment)).strip()


def modules(src: str):
    """The module sections: (id, title html, body html) in page order."""
    start = src.index('<h4 id="')
    end = src.index('<h3 id="planned">')
    region = src[start:end]
    parts = re.split(r'(?=<h4 id=")', region)
    out = []
    for part in parts:
        m = re.match(r'<h4 id="([^"]+)">(.*?)</h4>\n', part, re.S)
        if not m:
            continue
        out.append((m.group(1), m.group(2), part[m.end():].rstrip() + "\n"))
    return out


def summary(body: str) -> str:
    """A few API names, from the module's quick-jump list or its first table."""
    names = [text(n) for n in re.findall(r'<div class="api-list">(.*?)</div>', body, re.S)[:1]
             for n in re.findall(r"<a [^>]*>(.*?)</a>", n, re.S)]
    if not names:
        names = [text(c) for c in re.findall(r"<tr><td><code>(.*?)</code>", body, re.S)]
    seen, uniq = set(), []
    for n in names:
        n = n.split("(")[0].split(" ·")[0].strip()
        if n and n not in seen:
            seen.add(n)
            uniq.append(n)
    if not uniq:
        return ""
    return ", ".join(uniq[:4]) + (", …" if len(uniq) > 4 else "")


def relink(body: str, local_ids: set) -> str:
    """In-page anchors that point outside this module go to the full page."""
    return re.sub(r'href="#([^"]+)"',
                  lambda m: m.group(0) if m.group(1) in local_ids else f'href="/stdlib#{m.group(1)}"',
                  body)


def emit(path: Path, content: str, stale: list) -> None:
    if CHECK:
        if not path.exists() or path.read_text() != content:
            stale.append(str(path.relative_to(HERE.parent)))
        return
    path.write_text(content)


def fence(textv: str, start: str, end: str, fill: str, where: Path) -> str:
    pattern = re.compile(f"({re.escape(start)}).*?({re.escape(end)})", re.S)
    out, n = pattern.subn(lambda m: m.group(1) + "\n" + fill + "\n  " + m.group(2), textv, count=1)
    if n != 1:
        raise SystemExit(f"{where}: no {start} … {end} region")
    return out


def main():
    src = SRC.read_text()
    mods = modules(src)
    if not mods:
        raise SystemExit(f"{SRC}: no <h4 id=…> module sections found")
    stale = []
    if not CHECK:
        OUT.mkdir(exist_ok=True)

    titles = {mid: text(t) for mid, t, _ in mods}
    for i, (mid, title_html, body) in enumerate(mods):
        title = titles[mid]
        local_ids = set(re.findall(r'id="([^"]+)"', body)) | {mid}
        page_body = f'  <h1 id="{mid}">{title_html}</h1>\n' + relink(body, local_ids)
        sidebar = "\n".join(
            f'    <a href="/stdlib/{m}"{ACTIVE if m == mid else ""}>{titles[m]}</a>' for m, _, _ in mods)
        prevnext = []
        if i > 0:
            p = mods[i - 1][0]
            prevnext.append(f'    <a class="btn ghost" href="/stdlib/{p}">&larr; {titles[p]}</a>')
        if i + 1 < len(mods):
            n = mods[i + 1][0]
            prevnext.append(f'    <a class="btn ghost" href="/stdlib/{n}">{titles[n]} &rarr;</a>')
        apis = summary(body)
        desc = f"Lumen standard library: {title}" + (f" — {apis}" if apis else "") + ". Statically typed, compiled to native code."
        page = (SHELL.replace("@@TITLE@@", html.escape(title, quote=True))
                     .replace("@@ID@@", mid)
                     .replace("@@DESC@@", html.escape(desc, quote=True))
                     .replace("@@SIDEBAR@@", sidebar)
                     .replace("@@BODY@@", page_body)
                     .replace("@@PREVNEXT@@", "\n".join(prevnext)))
        emit(OUT / f"{mid}.html", page, stale)

    # The module index on the one-page reference.
    cards = ['  <div class="pkg-grid" id="module-index">']
    for mid, _, body in mods:
        cards.append(f'    <a class="pkg" href="/stdlib/{mid}">\n'
                     f'      <span class="pkg-name">{html.escape(titles[mid], quote=False)}</span>\n'
                     f'      <span class="pkg-summary">{html.escape(summary(body), quote=False)}</span>\n'
                     f'    </a>')
    cards.append("  </div>")
    emit(SRC, fence(src, "<!-- modules:start -->", "<!-- modules:end -->", "\n".join(cards), SRC), stale)

    # One sitemap entry per module page.
    urls = "\n".join(f"  <url><loc>https://lumen-lang.org/stdlib/{mid}</loc></url>" for mid, _, _ in mods)
    emit(SITEMAP, fence(SITEMAP.read_text(), "<!-- stdlib:start -->", "<!-- stdlib:end -->", urls, SITEMAP), stale)

    if CHECK:
        if stale:
            print("stale, regenerate with genstdlib.py:\n  " + "\n  ".join(stale))
            raise SystemExit(1)
        print(f"{len(mods)} module pages up to date")
        return
    print(f"{len(mods)} module pages: " + ", ".join(m for m, _, _ in mods))


if __name__ == "__main__":
    main()
