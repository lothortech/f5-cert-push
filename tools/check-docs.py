#!/usr/bin/env python3
"""Check that the HTML documentation matches the Markdown (what GitHub shows).

    python tools/check-docs.py

1. Every Markdown document (README.md, REVIEW.md, CHANGELOG.md, docs/*.md) has an HTML page.
2. html/ is up to date: the pages are rebuilt into a temporary directory and compared with
   html/ byte for byte (a page edited by hand, or not regenerated after a Markdown change, fails).
3. Every link resolves:
   - in the HTML pages: relative links point at an existing file, and #anchors at an existing id;
   - in the Markdown files (as GitHub resolves them): relative links point at an existing file,
     and #anchors to another document exist there.
Exits 1 if anything is wrong.
"""
import filecmp
import glob
import html.parser
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "html")
sys.path.insert(0, os.path.join(ROOT, "tools"))
problems = []


def bad(msg):
    problems.append(msg)
    print("FAIL  " + msg)


# ---- 1. every document has a page ------------------------------------------------
spec = {}
src = open(os.path.join(ROOT, "tools", "build-html.py"), encoding="utf-8").read()
for m in re.finditer(r'\("([^"]+\.md)", "([^"]+\.html)", "([^"]+)"\)', src):
    spec[m.group(1)] = m.group(2)
docs = ["README.md", "REVIEW.md", "CHANGELOG.md"] + sorted(
    os.path.relpath(p, ROOT).replace("\\", "/") for p in glob.glob(os.path.join(ROOT, "docs", "*.md")))
for d in docs:
    if d not in spec:
        bad("%s has no HTML page (add it to PAGES in tools/build-html.py)" % d)
print("pages: %d documents, %d pages" % (len(docs), len(spec)))

# ---- 2. html/ is what the Markdown produces ---------------------------------------------
with tempfile.TemporaryDirectory() as tmp:
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "build-html.py"), "--out", tmp],
                       capture_output=True, text=True)
    if r.returncode != 0:
        bad("tools/build-html.py failed: " + r.stderr.strip())
    else:
        fresh = sorted(os.listdir(tmp))
        have = sorted(f for f in os.listdir(HTML) if f.endswith(".html"))
        for f in sorted(set(fresh) | set(have)):
            if f not in have:
                bad("html/%s is missing (run python tools/build-html.py)" % f)
            elif f not in fresh:
                bad("html/%s is not generated from any document (stale)" % f)
            elif not filecmp.cmp(os.path.join(tmp, f), os.path.join(HTML, f), shallow=False):
                bad("html/%s differs from its Markdown source (run python tools/build-html.py)" % f)
print("up to date: compared %d page(s)" % len(spec))


# ---- 3a. links in the HTML pages ----------------------------------------------------------
class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.add(a["id"])
        if tag == "a" and a.get("href"):
            self.hrefs.append(a["href"])


pages = {}
for f in os.listdir(HTML):
    if f.endswith(".html"):
        p = Links()
        p.feed(open(os.path.join(HTML, f), encoding="utf-8").read())
        pages[f] = p
n = 0
for f, p in sorted(pages.items()):
    for h in p.hrefs:
        if re.match(r"^(https?:|mailto:)", h):
            continue
        n += 1
        path, _, frag = h.partition("#")
        target = f if not path else os.path.normpath(os.path.join("html", path)).replace("\\", "/")
        if path:
            full = os.path.join(ROOT, target)
            if not os.path.exists(full):
                bad("html/%s: link %s points at a missing file" % (f, h))
                continue
            target = os.path.basename(full) if target.startswith("html/") else None
        if frag and target in pages and frag not in pages[target].ids:
            bad("html/%s: link %s points at a missing anchor" % (f, h))
print("html links: %d relative link(s) checked" % n)

# ---- 3b. links in the Markdown files (as GitHub resolves them) ------------------------------
build = __import__("build-html")
slug = build.slugify


def md_ids(path):
    ids = set()
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^#{1,6}\s+(.*?)\s*$", line)
        if m:
            ids.add(slug(re.sub(r"[`*]", "", m.group(1)), "-"))
    return ids


n = 0
for d in docs:
    text = open(os.path.join(ROOT, d), encoding="utf-8").read()
    text = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
    for m in re.finditer(r"\]\(([^)\s]+)\)", text):
        h = m.group(1)
        if re.match(r"^(https?:|mailto:)", h):
            continue
        n += 1
        path, _, frag = h.partition("#")
        full = os.path.normpath(os.path.join(ROOT, os.path.dirname(d), path)) if path else os.path.join(ROOT, d)
        if not os.path.exists(full):
            bad("%s: link %s points at a missing file" % (d, h))
        elif frag and full.endswith(".md") and frag not in md_ids(full):
            bad("%s: link %s points at a missing heading" % (d, h))
print("markdown links: %d relative link(s) checked" % n)

print("RESULT: %s" % ("OK" if not problems else "%d problem(s)" % len(problems)))
sys.exit(1 if problems else 0)
