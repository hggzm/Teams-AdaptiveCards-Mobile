#!/usr/bin/env python3
"""
Generate an HTML catalog page for a11y screenshots + recordings.

Usage: python3 generate-a11y-catalog.py <artifacts_dir> <output_dir>

Reads PNGs and MP4s from artifacts_dir, generates a self-contained
HTML page with inline base64-encoded images and video links.
"""
import os
import sys
import base64
import shutil
from pathlib import Path
from datetime import datetime

artifacts_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-artifacts"
output_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/a11y-site"

os.makedirs(output_dir, exist_ok=True)

# Find all PNGs
screenshots = {}
for root, _, files in os.walk(artifacts_dir):
    for f in sorted(files):
        if f.endswith((".png", ".jpg", ".jpeg", ".JPEG")):
            path = os.path.join(root, f)
            name = Path(f).stem
            screenshots[name] = path

# Find recordings
recordings = {}
for root, _, files in os.walk(artifacts_dir):
    for f in sorted(files):
        if f.endswith(".mp4"):
            path = os.path.join(root, f)
            name = Path(f).stem
            recordings[name] = path

# Scenario metadata
SCENARIOS = [
    {"id": "showcard_collapsed", "title": "ShowCard Collapsed", "pr": "#663",
     "card": "ExpenseReport.json", "desc": "Reject button visible, ShowCard content hidden"},
    {"id": "showcard_expanded", "title": "ShowCard Expanded", "pr": "#663",
     "card": "ExpenseReport.json", "desc": "After tap: ShowCard content expanded, button selected=true"},
    {"id": "showcard_collapsed_again", "title": "ShowCard Re-collapsed", "pr": "#663",
     "card": "ExpenseReport.json", "desc": "After second tap: ShowCard hidden, button selected=false"},
    {"id": "validation_empty_form", "title": "Validation: Empty Form", "pr": "#662",
     "card": "InputForm.json", "desc": "Empty input form before submit"},
    {"id": "validation_error_visible", "title": "Validation: Error Visible", "pr": "#662",
     "card": "InputForm.json", "desc": "Error messages visible after submit with empty required fields"},
    {"id": "toggle_visibility_hidden", "title": "Toggle: Hidden", "pr": "--",
     "card": "ExpenseReport.json", "desc": "Show history text visible, content hidden"},
    {"id": "toggle_visibility_revealed", "title": "Toggle: Revealed", "pr": "--",
     "card": "ExpenseReport.json", "desc": "After tap: Hide history visible, content revealed"},
    {"id": "activity_showcard_buttons", "title": "Activity: Buttons", "pr": "--",
     "card": "ActivityUpdate.json", "desc": "Set due date and Comment action buttons visible"},
    {"id": "activity_showcard_expanded", "title": "Activity: ShowCard Expanded", "pr": "--",
     "card": "ActivityUpdate.json", "desc": "After Comment tap: inline ShowCard expanded"},
]

ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")


def img_to_base64(path):
    """Convert image file to base64 data URI."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        if len(data) < 100:
            return None
        ext = Path(path).suffix.lstrip(".").lower()
        if ext in ("jpg", "jpeg"):
            ext = "jpeg"
        return "data:image/{};base64,{}".format(ext, base64.b64encode(data).decode())
    except Exception:
        return None


def find_screenshot_for_scenario(scenario_id, index):
    """Find the best matching screenshot for a scenario."""
    for name, path in screenshots.items():
        if scenario_id in name.lower():
            return path
    # Match by index (screenshots are numbered 1_xxx, 2_xxx, etc.)
    idx = index + 1
    for name, path in screenshots.items():
        if name.startswith("{}_".format(idx)):
            return path
    return None


# Build cards HTML
cards_html = []
for i, sc in enumerate(SCENARIOS):
    img_path = find_screenshot_for_scenario(sc["id"], i)
    img_data = img_to_base64(img_path) if img_path else None
    if img_data:
        img_tag = '<img src="{}" alt="{}" class="ss">'.format(img_data, sc["title"])
    else:
        img_tag = '<div class="no-img">No screenshot captured</div>'

    if sc["pr"] != "--":
        pr_num = sc["pr"].lstrip("#")
        pr_link = '<a href="https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/{}" class="pr-link">{}</a>'.format(pr_num, sc["pr"])
    else:
        pr_link = "--"

    card = """
    <div class="card">
      <div class="card-hdr">
        <span class="card-title">{title}</span>
        <span class="card-pr">{pr}</span>
      </div>
      <div class="card-meta">
        <span class="card-file">{card_file}</span>
        <span class="card-desc">{desc}</span>
      </div>
      <div class="card-img">{img}</div>
    </div>""".format(
        title=sc["title"], pr=pr_link, card_file=sc["card"],
        desc=sc["desc"], img=img_tag
    )
    cards_html.append(card)

# Build recordings section
rec_html = ""
if recordings:
    rec_items = []
    for name, path in recordings.items():
        sz = os.path.getsize(path)
        sz_mb = "{:.1f}".format(sz / 1048576)
        rec_items.append("""
        <div class="rec-item">
          <div class="rec-icon">&#127909;</div>
          <div class="rec-info">
            <div class="rec-name">{name}.mp4</div>
            <div class="rec-size">{sz} MB &mdash; TalkBack screen recording with voiceover audio</div>
          </div>
          <a href="recordings/{name}.mp4" class="rec-dl" download>Download MP4</a>
        </div>""".format(name=name, sz=sz_mb))
    rec_html = """
    <div class="section">
      <h2>&#127909; TalkBack Recordings</h2>
      <p class="section-desc">Screen recordings captured with Android TalkBack enabled.</p>
      {items}
    </div>""".format(items="".join(rec_items))
    # Copy recordings to output
    rec_out = os.path.join(output_dir, "recordings")
    os.makedirs(rec_out, exist_ok=True)
    for name, path in recordings.items():
        shutil.copy2(path, os.path.join(rec_out, "{}.mp4".format(name)))

CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0d1117; color: #c9d1d9; }
.header { text-align: center; padding: 24px 16px; background: #161b22; border-bottom: 1px solid #30363d; }
.header h1 { font-size: 22px; color: #58a6ff; margin-bottom: 4px; }
.header p { font-size: 13px; color: #8b949e; }
.stats { display: flex; gap: 10px; justify-content: center; margin-top: 12px; flex-wrap: wrap; }
.stat { background: #21262d; padding: 4px 12px; border-radius: 16px; font-size: 12px; color: #8b949e; }
.stat b { color: #c9d1d9; }
.section { padding: 20px 16px; }
.section h2 { font-size: 17px; color: #58a6ff; margin-bottom: 8px; padding-bottom: 6px; border-bottom: 2px solid #30363d; }
.section-desc { font-size: 13px; color: #8b949e; margin-bottom: 16px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 14px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; overflow: hidden; transition: border-color 0.2s; }
.card:hover { border-color: #58a6ff; }
.card-hdr { padding: 8px 12px; background: #21262d; display: flex; justify-content: space-between; align-items: center; }
.card-title { font-size: 14px; font-weight: 600; color: #c9d1d9; }
.card-pr { font-size: 11px; }
.pr-link { color: #58a6ff; text-decoration: none; }
.card-meta { padding: 6px 12px; font-size: 11px; color: #8b949e; border-bottom: 1px solid #21262d; }
.card-file { background: #21262d; padding: 1px 6px; border-radius: 4px; margin-right: 6px; }
.card-desc { display: block; margin-top: 3px; }
.card-img { padding: 8px; text-align: center; }
.ss { max-width: 100%; max-height: 400px; border: 1px solid #30363d; border-radius: 4px; cursor: pointer; }
.ss:hover { border-color: #58a6ff; }
.no-img { color: #f85149; font-size: 12px; padding: 30px 0; }
.rec-item { display: flex; align-items: center; gap: 12px; padding: 12px; background: #161b22; border: 1px solid #30363d; border-radius: 8px; margin-bottom: 8px; }
.rec-icon { font-size: 28px; }
.rec-name { font-size: 14px; font-weight: 600; }
.rec-size { font-size: 12px; color: #8b949e; }
.rec-dl { padding: 6px 14px; background: #238636; color: white; border-radius: 6px; text-decoration: none; font-size: 12px; font-weight: 600; }
.rec-dl:hover { background: #2ea043; }
.footer { text-align: center; padding: 16px; font-size: 11px; color: #484f58; border-top: 1px solid #21262d; }
"""

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>A11y Screenshot Catalog - AdaptiveCards Android</title>
<style>{css}</style>
</head>
<body>
<div class="header">
  <h1>&#9855; Accessibility Screenshot Catalog</h1>
  <p>AdaptiveCards Android SDK &mdash; Generated {ts}</p>
  <div class="stats">
    <span class="stat">Screenshots: <b>{n_screenshots}</b></span>
    <span class="stat">Recordings: <b>{n_recordings}</b></span>
    <span class="stat">Scenarios: <b>{n_scenarios}</b></span>
  </div>
</div>
{rec_html}
<div class="section">
  <h2>&#128247; Accessibility Scenarios</h2>
  <p class="section-desc">Before/after screenshots demonstrating accessibility interactions. Click any image to view full size.</p>
  <div class="grid">
    {cards}
  </div>
</div>
<div class="footer">
  AdaptiveCards Mobile SDK &mdash; Accessibility Validation Pipeline
</div>
<script>
document.querySelectorAll('.ss').forEach(function(img) {{
  img.addEventListener('click', function() {{ window.open(this.src, '_blank'); }});
}});
</script>
</body>
</html>""".format(
    css=CSS,
    ts=ts,
    n_screenshots=len(screenshots),
    n_recordings=len(recordings),
    n_scenarios=len(SCENARIOS),
    rec_html=rec_html,
    cards="".join(cards_html),
)

with open(os.path.join(output_dir, "index.html"), "w") as f:
    f.write(HTML)
open(os.path.join(output_dir, ".nojekyll"), "w").close()

print("Generated catalog: {} screenshots, {} recordings".format(
    len(screenshots), len(recordings)))
print("Output: {}/index.html".format(output_dir))
