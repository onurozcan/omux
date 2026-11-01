#!/usr/bin/env python3
"""Turns CHANGELOG.md into site/changelog.html, in the landing page's style.

Run after editing the changelog: python3 scripts/build-changelog.py
"""
import html, re, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
source = (root / "CHANGELOG.md").read_text()
out = root / "site" / "changelog.html"

def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    return text

releases = []  # [{version, date, intro: [], sections: [(kind, [items])]}]
current = None; section = None
for raw in source.splitlines():
    line = raw.rstrip()
    m = re.match(r"^## \[?([^\]]+?)\]?(?: - (\d{4}-\d{2}-\d{2}))?$", line)
    if m:
        current = {"version": m.group(1), "date": m.group(2), "intro": [], "sections": []}
        releases.append(current); section = None
        continue
    if current is None or re.match(r"^\[[^\]]+\]: ", line):
        continue
    m = re.match(r"^### (.+)$", line)
    if m:
        section = (m.group(1), []); current["sections"].append(section); continue
    m = re.match(r"^- (.+)$", line)
    if m:
        target = section[1] if section else current.setdefault("items", [])
        target.append(m.group(1)); continue
    if line.strip() and section is None:
        current["intro"].append(line.strip())

def pretty_date(iso):
    import datetime
    d = datetime.date.fromisoformat(iso)
    return d.strftime("%B %-d, %Y")

def entries(kind, items):
    return "".join(f'<li class="entry"><span class="chip chip-{kind.lower()}">{html.escape(kind)}</span><div class="entry-text">{inline(x)}</div></li>\n' for x in items)

parts = []
for i, r in enumerate(releases):
    badge = '<span class="badge badge-latest">Latest</span>' if i == 0 else ""
    date = f'<time datetime="{r["date"]}">{pretty_date(r["date"])}</time>' if r["date"] else ""
    body = ""
    for p_ in r["intro"]:
        body += f"<p class=\"release-intro\">{inline(p_)}</p>\n"
    rows = entries("Added", r.get("items", []))
    for kind, items in r["sections"]:
        rows += entries(kind, items)
    body += f"<ul class=\"entries\">\n{rows}</ul>\n"
    tag = html.escape(r["version"])
    parts.append(f'''<article class="release" id="v{tag}">
  <div class="release-rail"><span class="node"></span></div>
  <div class="release-meta">
    <h2><a href="#v{tag}">{tag}</a></h2>
    {badge}
    <p>{date}</p>
    <p><a href="https://github.com/onurozcan/omux/releases/tag/v{tag}">Release on GitHub</a></p>
  </div>
  <div class="release-body">
{body}  </div>
</article>''')

page = f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Changelog – omux</title>
  <meta name="description" content="What changed in each omux release.">
  <link rel="canonical" href="https://omux.app/changelog">
  <meta name="theme-color" content="#0F0F0F">
  <meta name="color-scheme" content="dark">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="omux">
  <meta property="og:url" content="https://omux.app/changelog">
  <meta property="og:title" content="omux changelog">
  <meta property="og:description" content="What changed in each omux release.">
  <meta property="og:image" content="https://omux.app/social-preview.png">
  <meta name="twitter:card" content="summary_large_image">
  <link rel="icon" href="favicon.svg" type="image/svg+xml">
  <link rel="apple-touch-icon" href="apple-touch-icon.png">
  <link rel="stylesheet" href="style.css?v=7">
</head>
<body>

<header class="site-header">
  <div class="container header-row">
    <a class="brand" href="/" aria-label="omux home">
      <img src="favicon.svg" alt="" width="28" height="28">
      <span>omux</span>
    </a>
    <nav class="site-nav" aria-label="Primary">
      <a href="/#features">Features</a>
      <a href="/#install">Install</a>
      <a href="https://github.com/onurozcan/omux">GitHub</a>
      <a class="btn btn-small btn-primary" href="https://github.com/onurozcan/omux/releases/latest" data-download>Download</a>
    </nav>
  </div>
</header>

<main class="section">
  <div class="container changelog">
    <h1>Changelog</h1>
    <p class="lede muted">What changed in each release, newest first. Versions follow <a href="https://semver.org">semantic versioning</a>; the source is <a href="https://github.com/onurozcan/omux/blob/main/CHANGELOG.md">CHANGELOG.md</a>.</p>
<div class="timeline">
{chr(10).join(parts)}
</div>
  </div>
</main>

<footer class="site-footer">
  <div class="container">
    <nav class="footer-links" aria-label="Footer">
      <a href="https://github.com/onurozcan/omux">GitHub</a>
      <a href="https://github.com/onurozcan/omux/releases">Releases</a>
      <a href="/changelog">Changelog</a>
      <a href="https://github.com/onurozcan/omux/issues">Issues</a>
      <a href="https://github.com/onurozcan/omux/blob/main/LICENSE">MIT license</a>
    </nav>
    <p class="fineprint">omux is an independent project, not affiliated with or endorsed by Anthropic or OpenAI. Claude and Claude Code are trademarks of Anthropic; Codex is a trademark of OpenAI.</p>
  </div>
</footer>
<script src="main.js" defer></script>
</body>
</html>
'''
out.write_text(page)
print(f"wrote {out.relative_to(root)}: {len(releases)} releases")
