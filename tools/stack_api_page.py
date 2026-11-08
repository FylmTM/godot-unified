#!/usr/bin/env python3
"""Builds docs/stack-api.html: the C++ / Odin / Rust core APIs side by side, one concept per section.
usage: python3 tools/stack_api_page.py <api-cpp.json> <api-odin.json> <api-rust.json> <commentary.json> [out.html]
The api-*.json files hold per-section snippets (real code from impl/<lang> or marked sketches); commentary.json
holds the per-section framing and the summary. The output is one self-contained HTML file (no network needed;
web fonts are optional and fall back to system fonts)."""
import html, json, sys
from pathlib import Path

LANGS = [("cpp", "C++"), ("odin", "Odin"), ("rust", "Rust")]


def esc(s):
    return html.escape(s or "", quote=True)


def main():
    cpp, odin, rust, com = (json.loads(Path(p).read_text()) for p in sys.argv[1:5])
    out = Path(sys.argv[5] if len(sys.argv) > 5 else "docs/stack-api.html")
    data = {"cpp": cpp, "odin": odin, "rust": rust}
    by_id = {k: {s["id"]: s for s in v["sections"]} for k, v in data.items()}

    nav, body = [], []
    for group in com["groups"]:
        nav.append(f'<li class="nav-group">{esc(group["title"])}</li>')
        body.append(f'<h2 class="group-title" id="g-{esc(group["id"])}">{esc(group["title"])}</h2>')
        for sec in group["sections"]:
            sid = sec["id"]
            nav.append(f'<li><a href="#{esc(sid)}">{esc(sec["title"])}</a></li>')
            edge = sec.get("edge", "")
            edge_html = f'<span class="edge">{esc(edge)}</span>' if edge else ""
            cols = []
            for key, name in LANGS:
                s = by_id[key].get(sid)
                if not s:
                    cols.append(f'<div class="col col-{key}"><div class="col-head"><span class="lang">{name}</span></div><p class="missing">Not covered.</p></div>')
                    continue
                status = s.get("status", "real")
                src = s.get("source", "")
                src_html = f'<span class="src">{esc(src)}</span>' if src and status != "sketch" else ""
                lang_cls = {"cpp": "cpp", "odin": "odin", "rust": "rust"}[key]
                code_lang = "tree" if sid in ("layout", "build") else lang_cls
                cols.append(
                    f'<div class="col col-{key}">'
                    f'<div class="col-head"><span class="lang">{name}</span>'
                    f'<span class="status status-{esc(status)}">{esc(status)}</span>{src_html}</div>'
                    f'<pre class="code" data-lang="{code_lang}"><code>{esc(s.get("code", ""))}</code></pre>'
                    f'<p class="note">{esc(s.get("note", ""))}</p></div>')
            body.append(
                f'<section class="concept" id="{esc(sid)}">'
                f'<header class="concept-head"><h3>{esc(sec["title"])}</h3>{edge_html}</header>'
                f'<p class="look">{esc(sec.get("look_for", ""))}</p>'
                f'<div class="cols">{"".join(cols)}</div></section>')

    summary_rows = "".join(
        f'<tr><th scope="row">{esc(r["topic"])}</th>'
        + "".join(f'<td class="{esc(r.get("mark_" + k, ""))}">{esc(r.get(k, ""))}</td>' for k, _ in LANGS)
        + "</tr>" for r in com["summary"])
    lists = []
    for key, name in LANGS:
        pts = "".join(f"<li>{esc(p)}</li>" for p in data[key].get("pain_points", []))
        good = "".join(f"<li>{esc(p)}</li>" for p in data[key].get("strengths", []))
        lists.append(f'<div class="col col-{key}"><div class="col-head"><span class="lang">{name}</span></div>'
                     f'<h4>Strengths</h4><ul>{good}</ul><h4>Pain points</h4><ul>{pts}</ul></div>')

    page = TEMPLATE.replace("{{INTRO}}", com["intro_html"]).replace("{{SUMMARY_ROWS}}", summary_rows) \
        .replace("{{NAV}}", "".join(nav)).replace("{{BODY}}", "".join(body)).replace("{{LISTS}}", "".join(lists)) \
        .replace("{{CLOSING}}", com.get("closing_html", ""))
    out.write_text(page)
    print(f"wrote {out} ({len(page)//1024} KB)")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>unified Core API Atlas</title>
<meta name="claude:viewport-fit-sides" content="cover">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:wght@500;700;800&family=JetBrains+Mono:wght@400;600&display=swap">
<style>
/* Layout: a reference atlas. One concept per section, three language columns that line up across the page;
   a sticky header carries the column labels so the eye never loses which column is which. */
:root {
  --bg: #f6f7f9; --panel: #ffffff; --ink: #161b22; --muted: #5a6472; --rule: #d9dee5;
  --code-bg: #f1f3f6; --accent: #2d4bd6;
  --cpp: #3b6ac9; --odin: #1f8a7a; --rust: #b4532a;
  --tk-kw: #8a2bb0; --tk-str: #1d7a3a; --tk-num: #a0520e; --tk-com: #7b8794; --tk-type: #1f5fae; --tk-attr: #9a6b00;
  --good: #1d7a3a; --warn: #9a6b00; --bad: #b3261e;
  --font-display: "Schibsted Grotesk", "Helvetica Neue", Arial, system-ui, sans-serif;
  --font-body: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --font-code: "JetBrains Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg: #0f1216; --panel: #161a20; --ink: #e6e9ee; --muted: #9aa4b2; --rule: #2a313b; --code-bg: #12161b; --accent: #8ea2ff;
  --cpp: #7fa3ee; --odin: #4fc3b0; --rust: #e2885f;
  --tk-kw: #d39bf0; --tk-str: #7ccf8f; --tk-num: #e8a86a; --tk-com: #6f7b89; --tk-type: #7fb4f0; --tk-attr: #e3c069;
  --good: #7ccf8f; --warn: #e3c069; --bad: #f2867c; color-scheme: dark; } }
:root[data-theme="dark"] {
  --bg: #0f1216; --panel: #161a20; --ink: #e6e9ee; --muted: #9aa4b2; --rule: #2a313b; --code-bg: #12161b; --accent: #8ea2ff;
  --cpp: #7fa3ee; --odin: #4fc3b0; --rust: #e2885f;
  --tk-kw: #d39bf0; --tk-str: #7ccf8f; --tk-num: #e8a86a; --tk-com: #6f7b89; --tk-type: #7fb4f0; --tk-attr: #e3c069;
  --good: #7ccf8f; --warn: #e3c069; --bad: #f2867c; color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.55 var(--font-body); }
body::before { content: ""; position: fixed; inset: 0 0 auto; height: env(safe-area-inset-top, 0px); z-index: 10; background: var(--panel); }
.wrap { padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); }
a { color: var(--accent); }
a:focus-visible, button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.masthead { padding-block: 40px 24px; max-width: 1500px; margin: 0 auto; }
.masthead h1 { font: 800 clamp(30px, 4.4vw, 52px)/1.05 var(--font-display); letter-spacing: -0.02em; margin: 0 0 12px; text-wrap: balance; }
.masthead .kicker { font: 600 12px/1 var(--font-code); text-transform: uppercase; letter-spacing: .12em; color: var(--muted); margin: 0 0 14px; }
.intro { max-width: 72ch; color: var(--ink); }
.intro p { margin: 0 0 10px; }
.legend { display: flex; flex-wrap: wrap; gap: 8px 18px; margin-top: 14px; font-size: 13px; color: var(--muted); }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.sticky { position: sticky; top: env(safe-area-inset-top, 0px); z-index: 5; background: var(--panel); border-bottom: 1px solid var(--rule); }
.sticky .bar { max-width: 1500px; margin: 0 auto; display: grid; grid-template-columns: 220px 1fr; gap: 20px; align-items: center; padding-block: 10px; }
.sticky .labels { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
.sticky .labels span { font: 700 15px/1 var(--font-display); padding-left: 10px; border-left: 4px solid; }
.sticky .tools { display: flex; gap: 8px; align-items: center; font-size: 13px; color: var(--muted); }
.tools button { font: 600 12px var(--font-body); border: 1px solid var(--rule); background: var(--bg); color: var(--ink); border-radius: 6px; padding: 5px 9px; cursor: pointer; }
.tools button[aria-pressed="true"] { background: var(--ink); color: var(--panel); }
.lbl-cpp { border-color: var(--cpp) !important; } .lbl-odin { border-color: var(--odin) !important; } .lbl-rust { border-color: var(--rust) !important; }
.layout { max-width: 1500px; margin: 0 auto; display: grid; grid-template-columns: 220px minmax(0, 1fr); gap: 20px; padding-block: 24px 80px; }
nav.toc { position: sticky; top: calc(env(safe-area-inset-top, 0px) + 64px); align-self: start; max-height: calc(100vh - 90px); overflow: auto; font-size: 13.5px; }
nav.toc ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 2px; }
nav.toc .nav-group { font: 700 11px/1 var(--font-code); text-transform: uppercase; letter-spacing: .1em; color: var(--muted); margin-top: 14px; padding-bottom: 4px; }
nav.toc a { color: var(--ink); text-decoration: none; display: block; padding: 3px 8px; border-radius: 5px; }
nav.toc a:hover, nav.toc a.active { background: var(--code-bg); color: var(--accent); }
main { min-width: 0; display: grid; gap: 30px; }
.summary { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; padding: 18px 18px 8px; }
.summary h2 { font: 800 22px/1.2 var(--font-display); margin: 0 0 10px; }
.table-scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 14px; }
th, td { text-align: left; vertical-align: top; padding: 9px 10px; border-top: 1px solid var(--rule); }
thead th { font: 700 13px var(--font-display); border-top: 0; }
tbody th { font-weight: 600; width: 22%; }
td.good { color: var(--good); } td.warn { color: var(--warn); } td.bad { color: var(--bad); }
h2.group-title { font: 800 28px/1.1 var(--font-display); letter-spacing: -0.01em; margin: 26px 0 -8px; padding-top: 6px; border-top: 3px solid var(--ink); }
.concept { scroll-margin-top: 80px; }
.concept-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 14px; }
.concept-head h3 { font: 700 21px/1.2 var(--font-display); margin: 0; text-wrap: balance; }
.edge { font: 600 12px/1 var(--font-code); color: var(--accent); border: 1px solid var(--accent); border-radius: 999px; padding: 4px 9px; }
.look { margin: 6px 0 12px; max-width: 90ch; color: var(--muted); }
.cols { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
.col { min-width: 0; display: flex; flex-direction: column; gap: 8px; background: var(--panel); border: 1px solid var(--rule); border-top: 4px solid; border-radius: 8px; padding: 10px; }
.col-cpp { border-top-color: var(--cpp); } .col-odin { border-top-color: var(--odin); } .col-rust { border-top-color: var(--rust); }
.col-head { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: center; font-size: 12px; }
.col-head .lang { font: 700 14px var(--font-display); }
.status { font: 600 10.5px/1 var(--font-code); text-transform: uppercase; letter-spacing: .08em; padding: 3px 6px; border-radius: 4px; border: 1px solid var(--rule); color: var(--muted); }
.status-real { color: var(--good); border-color: var(--good); }
.status-sketch { color: var(--warn); border-color: var(--warn); border-style: dashed; }
.status-mixed { color: var(--accent); border-color: var(--accent); }
.src { font: 11.5px var(--font-code); color: var(--muted); overflow-wrap: anywhere; }
pre.code { margin: 0; background: var(--code-bg); border-radius: 6px; padding: 10px 12px; overflow: auto; max-height: 560px; font: 12.5px/1.5 var(--font-code); tab-size: 4; }
body.wrap-code pre.code { white-space: pre-wrap; overflow-wrap: anywhere; }
pre.code .k { color: var(--tk-kw); } pre.code .s { color: var(--tk-str); } pre.code .n { color: var(--tk-num); }
pre.code .c { color: var(--tk-com); font-style: italic; } pre.code .t { color: var(--tk-type); } pre.code .a { color: var(--tk-attr); }
.note { margin: 0; font-size: 13.5px; }
.missing { color: var(--muted); font-style: italic; }
body.hide-sketch .col:has(.status-sketch) pre.code, body.hide-sketch .col:has(.status-sketch) .note { display: none; }
.lists .cols .col h4 { font: 700 13px var(--font-display); text-transform: uppercase; letter-spacing: .08em; margin: 6px 0 0; color: var(--muted); }
.lists ul { margin: 0; padding-left: 18px; display: grid; gap: 6px; font-size: 14px; }
.closing { max-width: 80ch; }
@media (max-width: 1100px) {
  .layout, .sticky .bar { grid-template-columns: minmax(0, 1fr); }
  nav.toc { display: none; }
}
@media (max-width: 820px) {
  .cols { grid-template-columns: minmax(0, 1fr); }
  .sticky .labels { display: none; }
}
@media (prefers-reduced-motion: no-preference) { html { scroll-behavior: smooth; } }
</style>
</head>
<body>
<div class="wrap">
<header class="masthead">
<p class="kicker">unified · phase 2 · core API atlas</p>
<h1>The same core, written three ways</h1>
<div class="intro">{{INTRO}}</div>
<div class="legend"><span><span class="status status-real">real</span> code from impl/&lt;lang&gt;</span><span><span class="status status-sketch">sketch</span> how it would look; not built yet</span><span><span class="status status-mixed">mixed</span> real code plus a sketched part</span></div>
</header>
</div>
<div class="sticky wrap"><div class="bar"><div class="tools"><button type="button" id="wrap-toggle" aria-pressed="false">Wrap lines</button><button type="button" id="sketch-toggle" aria-pressed="false">Hide sketches</button></div>
<div class="labels"><span class="lbl-cpp">C++</span><span class="lbl-odin">Odin</span><span class="lbl-rust">Rust</span></div></div></div>
<div class="wrap"><div class="layout">
<nav class="toc" aria-label="Concepts"><ul><li class="nav-group">Overview</li><li><a href="#summary">Where they differ</a></li>{{NAV}}<li class="nav-group">Wrap-up</li><li><a href="#lists">Strengths and pain points</a></li></ul></nav>
<main>
<section class="summary" id="summary"><h2>Where they differ</h2><div class="table-scroll"><table><thead><tr><th>Topic</th><th>C++</th><th>Odin</th><th>Rust</th></tr></thead><tbody>{{SUMMARY_ROWS}}</tbody></table></div></section>
{{BODY}}
<section class="concept lists" id="lists"><header class="concept-head"><h3>Strengths and pain points, in each implementer's words</h3></header><div class="cols">{{LISTS}}</div></section>
<section class="closing">{{CLOSING}}</section>
</main></div></div>
<script>
(function () {
  var KW = {
    cpp: "alignas alignof auto bool break case catch char class const constexpr consteval continue default delete do double else enum explicit extern false float for friend if inline int long namespace new noexcept nullptr operator private protected public return short signed sizeof static static_assert static_cast reinterpret_cast struct switch template this throw true try typedef typename union unsigned using virtual void volatile while uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t size_t std",
    odin: "package import foreign proc struct enum union bit_set map dynamic distinct using when if else for in not_in switch case return defer or_return or_else break continue fallthrough cast transmute auto_cast nil true false context struct_tag where do size_of align_of offset_of type_of typeid_of type_info_of i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool b8 int uint rawptr string cstring any typeid rune",
    rust: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while u8 u16 u32 u64 i8 i16 i32 i64 f32 f64 usize isize bool str char Option Result Some None Ok Err Vec Box"
  };
  var RX = {};
  Object.keys(KW).forEach(function (l) {
    var kws = KW[l].split(" ").join("|");
    var attr = l === "rust" ? "#!?\\[[^\\]\\n]*\\]" : l === "odin" ? "@\\([^)\\n]*\\)|@\\w+|#\\w+" : "^\\s*#\\s*\\w+";
    RX[l] = new RegExp("(//[^\\n]*|/\\*[\\s\\S]*?\\*/)|(\"(?:\\\\.|[^\"\\\\])*\"|`[^`]*`)|(" + attr + ")|\\b(" + kws + ")\\b|\\b(0x[0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?[fFuUlL]*)\\b|\\b([A-Z][A-Za-z0-9_]*)\\b", "gm");
  });
  function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
  document.querySelectorAll("pre.code").forEach(function (pre) {
    var lang = pre.getAttribute("data-lang"); var rx = RX[lang]; if (!rx) return;
    var code = pre.querySelector("code"); var src = code.textContent; var out = ""; var last = 0; var m;
    rx.lastIndex = 0;
    while ((m = rx.exec(src)) !== null) {
      if (m[0].length === 0) { rx.lastIndex++; continue; }
      out += esc(src.slice(last, m.index));
      var cls = m[1] ? "c" : m[2] ? "s" : m[3] ? "a" : m[4] ? "k" : m[5] ? "n" : "t";
      out += '<span class="' + cls + '">' + esc(m[0]) + "</span>";
      last = m.index + m[0].length;
    }
    out += esc(src.slice(last)); code.innerHTML = out;
  });
  function toggle(id, cls) {
    var b = document.getElementById(id);
    b.addEventListener("click", function () {
      var on = b.getAttribute("aria-pressed") !== "true";
      b.setAttribute("aria-pressed", on ? "true" : "false");
      document.body.classList.toggle(cls, on);
    });
  }
  toggle("wrap-toggle", "wrap-code"); toggle("sketch-toggle", "hide-sketch");
  var links = Array.prototype.slice.call(document.querySelectorAll("nav.toc a"));
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        links.forEach(function (a) { a.classList.toggle("active", a.getAttribute("href") === "#" + e.target.id); });
      });
    }, { rootMargin: "-20% 0px -70% 0px" });
    document.querySelectorAll("section[id]").forEach(function (s) { io.observe(s); });
  }
})();
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
