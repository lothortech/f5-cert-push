#!/usr/bin/env python3
"""Build self-contained HTML versions of the documentation into ./html/.

    pip install markdown
    python tools/build-html.py

Each page is a single file (CSS inline, no scripts, no network) so it opens straight from disk in any browser.
The Markdown files remain the source; regenerate the HTML after editing them.
"""
import html
import os
import re
import sys

try:
    import markdown
except ImportError:
    sys.exit("needs the 'markdown' package:  pip install markdown")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "html")

# (source file relative to ROOT, output name, nav title)
PAGES = [
    ("README.md", "index.html", "Overview"),
    ("docs/USER-GUIDE.md", "USER-GUIDE.html", "User guide (manual use)"),
    ("docs/SETUP.md", "SETUP.html", "Server and BIG-IP setup"),
    ("docs/MANUAL-UPLOAD.md", "MANUAL-UPLOAD.html", "Uploaded certificates"),
    ("docs/CONFIGURATION.md", "CONFIGURATION.html", "Configuration reference"),
    ("docs/OPERATIONS.md", "OPERATIONS.html", "Operations"),
    ("docs/SECURITY.md", "SECURITY.html", "Security"),
    ("docs/TESTING.md", "TESTING.html", "Testing"),
    ("REVIEW.md", "REVIEW.html", "Review brief"),
    ("CHANGELOG.md", "CHANGELOG.html", "Changelog"),
]
BY_SRC = {src: out for src, out, _ in PAGES}

CSS = """
:root{--bg:#fff;--fg:#1d2330;--mut:#5b6577;--line:#d9dee7;--code:#f3f5f8;--acc:#0b5cad;--side:#f7f8fb;--warn:#fff7e0;--warnb:#e3b341}
@media (prefers-color-scheme:dark){:root{--bg:#14171d;--fg:#e4e8ef;--mut:#9aa5b8;--line:#2b3140;--code:#1d222c;--acc:#6cb2ff;--side:#191d25;--warn:#2a2412;--warnb:#a07c1c}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{display:flex;min-height:100vh}
nav{width:250px;flex:none;background:var(--side);border-right:1px solid var(--line);padding:20px 16px;position:sticky;top:0;align-self:flex-start;height:100vh;overflow:auto}
nav .t{font-weight:700;margin:0 0 12px}
nav a{display:block;padding:6px 10px;border-radius:6px;color:var(--fg);text-decoration:none;font-size:14px}
nav a:hover{background:var(--code)}
nav a.cur{background:var(--acc);color:#fff}
main{flex:1;min-width:0;max-width:60rem;padding:28px 36px 80px}
h1{font-size:2rem;margin:.2em 0 .6em}
h2{font-size:1.45rem;margin:2em 0 .6em;padding-bottom:.25em;border-bottom:1px solid var(--line)}
h3{font-size:1.15rem;margin:1.6em 0 .4em}
a{color:var(--acc)}
code{background:var(--code);padding:.12em .35em;border-radius:4px;font:0.88em ui-monospace,SFMono-Regular,Consolas,Menlo,monospace}
pre{background:var(--code);border:1px solid var(--line);border-radius:8px;padding:14px 16px;overflow:auto;line-height:1.45;position:relative}
pre code{background:none;padding:0;font-size:.86rem}
table{border-collapse:collapse;display:block;overflow:auto;max-width:100%;margin:1em 0}
th,td{border:1px solid var(--line);padding:7px 11px;text-align:left;vertical-align:top}
th{background:var(--code)}
blockquote{margin:1em 0;padding:.6em 1em;background:var(--warn);border-left:4px solid var(--warnb);border-radius:4px}
blockquote p{margin:.3em 0}
hr{border:0;border-top:1px solid var(--line);margin:2em 0}
.copy{position:absolute;top:6px;right:6px;font:12px system-ui;padding:3px 8px;border:1px solid var(--line);border-radius:5px;background:var(--bg);color:var(--mut);cursor:pointer}
footer{margin-top:3em;color:var(--mut);font-size:13px}
@media (max-width:820px){.wrap{display:block}nav{width:auto;height:auto;position:static;border-right:0;border-bottom:1px solid var(--line)}main{padding:20px 16px 60px}}
@media print{nav,.copy{display:none}main{max-width:none;padding:0}pre{white-space:pre-wrap}}
"""

# a tiny script that adds a "Copy" button to code blocks; the pages work without it
JS = """
document.querySelectorAll('pre').forEach(function(p){
  if(!navigator.clipboard){return}
  var b=document.createElement('button');b.className='copy';b.textContent='Copy';
  b.onclick=function(){navigator.clipboard.writeText(p.innerText.replace(/\\nCopy$/,'')).then(function(){b.textContent='Copied';setTimeout(function(){b.textContent='Copy'},1500)})};
  p.appendChild(b);
});
"""


def slugify(value, sep):
    """GitHub-style heading ids, so the in-page links in the Markdown keep working."""
    value = re.sub(r"[^\w\- ]", "", value.strip().lower())
    return re.sub(r"[ ]", sep, value)


def fix_links(text, src):
    """Point links at the .html pages, and at ../ for files that are not pages."""
    src_dir = os.path.dirname(src)

    def repl(m):
        label, target = m.group(1), m.group(2)
        if re.match(r"^(https?:|mailto:|#)", target):
            return m.group(0)
        path, _, frag = target.partition("#")
        full = os.path.normpath(os.path.join(src_dir, path)).replace("\\", "/")
        if full in BY_SRC:
            new = BY_SRC[full] + ("#" + frag if frag else "")
            if re.fullmatch(r"[\w./-]+\.md", label):
                label = label[:-3] + ".html"
        elif path:
            new = "../" + full + ("#" + frag if frag else "")
        else:
            return m.group(0)
        return "[%s](%s)" % (label, new)

    # skip fenced code blocks
    parts = re.split(r"(^```.*?^```)", text, flags=re.S | re.M)
    for i in range(0, len(parts), 2):
        parts[i] = re.sub(r"\[([^\]]*)\]\(([^)\s]+)\)", repl, parts[i])
    return "".join(parts)


def build():
    os.makedirs(OUT, exist_ok=True)
    nav_items = [(out, title) for _, out, title in PAGES]
    for src, out, title in PAGES:
        path = os.path.join(ROOT, src)
        if not os.path.exists(path):
            print("skip (missing):", src)
            continue
        with open(path, encoding="utf-8") as f:
            text = fix_links(f.read(), src)
        md = markdown.Markdown(
            extensions=["tables", "fenced_code", "toc", "sane_lists"],
            extension_configs={"toc": {"slugify": slugify}},
        )
        body = md.convert(text)
        m = re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S)
        heading = re.sub(r"<[^>]+>", "", m.group(1)) if m else title
        nav = "".join(
            '<a href="%s"%s>%s</a>' % (o, ' class="cur"' if o == out else "", html.escape(t))
            for o, t in nav_items
        )
        page = (
            '<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>%s</title><style>%s</style></head><body><div class=\"wrap\">"
            '<nav><p class="t">f5-cert-push</p>%s</nav><main>%s'
            "<footer>Generated from <code>%s</code>. Edit the Markdown file and run "
            "<code>python tools/build-html.py</code> to regenerate.</footer></main></div>"
            "<script>%s</script></body></html>"
        ) % (html.escape(heading), CSS, nav, body, html.escape(src), JS)
        with open(os.path.join(OUT, out), "w", encoding="utf-8", newline="\n") as f:
            f.write(page)
        print("wrote html/" + out)


if __name__ == "__main__":
    build()
