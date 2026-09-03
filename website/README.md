# Lumen website

A static showcase site for the Lumen language — pure HTML/CSS/JS, **no build step
and no compiler required**.

## Files

- `index.html` — landing page (hero, feature cards, benchmarks, quickstart)
- `learn.html` — the language tour, one verified sample per topic (each sample
  was type-checked with the released compiler and, where the wasm target
  allows, compiled and run to confirm the output comments)
- `examples.html` — runnable example programs
- `play.html` — browser playground (compiles via `play-api.lumen-lang.org`)
- `stdlib.html` — standard-library reference
- `roadmap.html` — what is not there yet and why, module by module
- `community.html` — repository, issues, releases, how to contribute
- `404.html` — served by Cloudflare Pages for unknown paths
- `packages.html` — package catalog; `packages/<name>.html` — one page per
  std-contrib package, generated from its README by `genpages.py` (run
  manually when a README changes — the output is committed, so serving the
  site still needs no build step)
- `style.css` — styling
- `highlight.js` — tiny self-contained syntax highlighter
- `site.js` — shared behaviour: current-page nav highlight, theme toggle,
  Copy buttons on code blocks, "Open in playground" links on blocks marked
  `data-play` (the code travels in the URL as `/play#code=<base64url>`), and
  the latest-release line
- `stamp.py` — rewrites every `style.css` / `site.js` / `highlight.js` link
  with a `?v=<content hash>`. Cloudflare caches those files for five minutes,
  so without the stamp a browser can pair new HTML with an old stylesheet.
  **Run `python3 website/stamp.py` after editing any of the three**, before
  committing; `--check` is the CI form.

## Local preview

Just open `index.html` in a browser, or serve the folder:

```sh
python3 -m http.server -d website 8000
# open http://localhost:8000
```

## Cloudflare Pages

Connect the repo and configure:

- **Build command:** *(leave empty)*
- **Build output directory:** `website`
- **Framework preset:** None

Cloudflare serves the folder as-is. Pushing to the production branch redeploys.
