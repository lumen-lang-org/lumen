// Shared page behaviour, loaded by every page after the content:
//   1. mark the top-nav link for the page being viewed (aria-current), so a
//      reader on /stdlib can see where they are;
//   2. give every code block a Copy button, and any block marked
//      data-play an "Open in playground" link that carries the code over in
//      the URL fragment (play.html reads #code=…);
//   3. the older "copy this element's text" buttons (the hero install row).
// No dependencies; the page works without it.
(function () {
  // Base64url of a UTF-8 string, the encoding play.html decodes.
  function encodeCode(src) {
    var bytes = new TextEncoder().encode(src);
    var bin = "";
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function flash(btn, text) {
    var was = btn.textContent;
    btn.textContent = text;
    btn.classList.add("ok");
    setTimeout(function () { btn.textContent = was; btn.classList.remove("ok"); }, 1400);
  }

  function copyText(text, btn) {
    if (!navigator.clipboard) return;
    navigator.clipboard.writeText(text).then(function () { flash(btn, "Copied"); });
  }

  // 1. Current page in the top nav. Hash links (Features, Install) only
  //    count on the home page itself.
  var path = location.pathname.replace(/\.html$/, "").replace(/\/index$/, "/");
  document.querySelectorAll("nav .links a").forEach(function (a) {
    var href = a.getAttribute("href") || "";
    if (/^https?:/.test(href)) return;
    var target = href.split("#")[0] || "/";
    if (href.indexOf("#") >= 0 && target === "/") return;
    var here = target === "/" ? path === "/" : (path === target || path.indexOf(target + "/") === 0);
    if (here) a.setAttribute("aria-current", "page");
  });

  // 2. Code-block tools. The <pre> is wrapped so the buttons stay put while
  //    a wide block scrolls horizontally underneath them.
  document.querySelectorAll("pre").forEach(function (pre) {
    if (pre.id === "output" || pre.closest(".no-tools")) return;
    var code = pre.querySelector("code");
    var src = (code || pre).textContent;
    if (!src.trim()) return;

    var wrap = document.createElement("div");
    wrap.className = "codeblock";
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);

    var tools = document.createElement("div");
    tools.className = "pre-tools";

    if (pre.hasAttribute("data-play")) {
      var run = document.createElement("a");
      run.href = "/play#code=" + encodeCode(src);
      run.textContent = "Open in playground";
      run.title = "Load this program in the browser playground";
      tools.appendChild(run);
    }

    var copy = document.createElement("button");
    copy.type = "button";
    copy.textContent = "Copy";
    copy.setAttribute("aria-label", "Copy code");
    copy.addEventListener("click", function () { copyText(src, copy); });
    tools.appendChild(copy);

    wrap.appendChild(tools);
  });

  // 3. Buttons that copy a named element's text (the install one-liner).
  document.querySelectorAll(".copy[data-copy]").forEach(function (b) {
    b.addEventListener("click", function () {
      var el = document.getElementById(b.dataset.copy);
      if (el) copyText(el.textContent, b);
    });
  });

  // 4. Theme toggle. The choice is pinned on <html data-theme> and remembered;
  //    with nothing stored the page follows the OS (see the head script and
  //    style.css). Clicking flips whichever theme is showing now.
  document.querySelectorAll(".theme-toggle").forEach(function (b) {
    b.addEventListener("click", function () {
      var root = document.documentElement;
      var showing = root.getAttribute("data-theme") ||
        (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      var next = showing === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem("theme", next); } catch (e) {}
    });
  });

  // 5. Latest release, filled from GitHub's public API into any
  //    [data-latest-release] element. Silent when the API is unreachable.
  var rel = document.querySelectorAll("[data-latest-release]");
  if (rel.length && window.fetch) {
    fetch("https://api.github.com/repos/lumen-lang-org/lumen/releases/latest")
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) {
        if (!j || !j.tag_name) return;
        var when = j.published_at ? new Date(j.published_at) : null;
        rel.forEach(function (el) {
          el.textContent = "Latest release: ";
          var a = document.createElement("a");
          a.href = j.html_url;
          a.textContent = j.tag_name;
          el.appendChild(a);
          if (when && !isNaN(when)) {
            el.appendChild(document.createTextNode(" · " + when.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" })));
          }
        });
      })
      .catch(function () {});
  }
})();
