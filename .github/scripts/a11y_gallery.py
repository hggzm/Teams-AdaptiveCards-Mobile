#!/usr/bin/env python3
"""Generate HTML gallery for iOS a11y screenshots with annotated overlays.
Shows raw vs annotated side-by-side, transcript table, and video."""
import json, os, sys

pages_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/axe-pages"

# Load transcript
transcript_path = os.path.join(pages_dir, "a11y_transcript.json")
transcript = []
if os.path.exists(transcript_path):
    with open(transcript_path) as f:
        transcript = json.load(f)

# Build scenario comparison cards
scenario_html = ""
for scenario in transcript:
    name = scenario.get("scenario", "unknown")
    nodes = scenario.get("nodes", [])
    raw_img = name + ".png"
    ann_img = "annotated_" + name + ".png"

    scenario_html += '<h2>{}</h2>\n'.format(name.replace("_", " ").title())
    scenario_html += '<div class="compare">\n'
    scenario_html += '  <div class="card"><h3>Raw Screenshot</h3>'
    scenario_html += '<img src="{}" alt="raw"></div>\n'.format(raw_img)
    scenario_html += '  <div class="card"><h3>A11y Element Overlay</h3>'
    scenario_html += '<img src="{}" alt="annotated"></div>\n'.format(ann_img)
    scenario_html += '</div>\n'

    # Transcript table for this scenario
    if nodes:
        scenario_html += '<details><summary>{} VoiceOver elements</summary>\n'.format(len(nodes))
        scenario_html += '<table class="transcript"><thead><tr>'
        scenario_html += '<th>#</th><th>Role</th><th>Label</th><th>Value</th><th>VoiceOver Reads</th><th>Bounds</th>'
        scenario_html += '</tr></thead><tbody>\n'
        for node in nodes:
            vo = node.get("voiceover_reads", "")
            bounds = node.get("bounds", [0,0,0,0])
            scenario_html += '<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td class="vo">{}</td><td class="bounds">{}</td></tr>\n'.format(
                node.get("index", ""),
                node.get("role", ""),
                node.get("label", "")[:40],
                node.get("value", "") or "",
                vo[:60],
                "{},{},{},{}".format(*bounds) if len(bounds) == 4 else str(bounds)
            )
        scenario_html += '</tbody></table></details>\n'

html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>iOS A11y Screenshot Gallery</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, sans-serif; background: #0d1117; color: #c9d1d9; padding: 2rem; }
    h1 { color: #58a6ff; margin-bottom: 1rem; }
    h2 { color: #f0f6fc; margin: 2rem 0 1rem; border-bottom: 1px solid #30363d; padding-bottom: 0.5rem; }
    h3 { color: #8b949e; margin-bottom: 0.5rem; font-size: 0.9rem; }
    .meta { color: #8b949e; margin-bottom: 2rem; }
    .compare { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin: 1rem 0; }
    .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 1rem; }
    .card img { width: 100%%; display: block; border-radius: 4px; }
    video { width: 100%%; max-width: 500px; border-radius: 8px; border: 1px solid #30363d; margin: 1rem 0; }
    details { margin: 1rem 0; }
    summary { cursor: pointer; color: #58a6ff; font-weight: 600; }
    table.transcript { width: 100%%; border-collapse: collapse; margin: 0.5rem 0; font-size: 0.85rem; }
    table.transcript th { background: #161b22; color: #8b949e; padding: 6px 8px; text-align: left; border-bottom: 2px solid #30363d; }
    table.transcript td { padding: 6px 8px; border-bottom: 1px solid #21262d; }
    .vo { color: #58a6ff; font-style: italic; }
    .bounds { font-family: monospace; font-size: 0.8rem; color: #8b949e; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
    .badge-pass { background: #238636; color: white; }
    .badge-info { background: #1f6feb; color: white; }
    .links { margin: 1rem 0; }
    .links a { color: #58a6ff; margin-right: 1rem; }
  </style>
</head>
<body>
  <h1>iOS Accessibility Screenshot Gallery</h1>
  <div class="meta">
    <span class="badge badge-pass">XCUIElement API</span>
    <span class="badge badge-info">%(total_elements)s ELEMENTS</span>
    <span class="badge badge-info">%(scenario_count)s SCENARIOS</span>
  </div>
  <div class="links">
    <a href="a11y_transcript.json">Transcript JSON</a>
    <a href="voiceover_demo.mp4">Video Recording</a>
    <a href="timeline.json">Pipeline Metadata</a>
  </div>

  <h2>Video Recording</h2>
  <video controls preload="metadata">
    <source src="voiceover_demo.mp4" type="video/mp4">
  </video>
  <p style="color:#8b949e;">XCUITest interactions recorded via AXe record-video.</p>

  %(scenarios)s

  <h2>Data Source</h2>
  <div class="card" style="max-width:600px;">
    <p><strong>Platform:</strong> iOS (XCUIElement)</p>
    <p><strong>API:</strong> UIAccessibility (accessibilityLabel, accessibilityValue, frame)</p>
    <p><strong>Overlays:</strong> Pillow (numbered colored bounding boxes at element coordinates)</p>
    <p><strong>Narration:</strong> macOS say (Samantha voice from element labels)</p>
    <p>All element data comes from the same UIAccessibility properties that VoiceOver queries at runtime.</p>
  </div>
</body>
</html>
"""

total_elements = sum(len(s.get("nodes", [])) for s in transcript)
html = html % {
    "total_elements": total_elements,
    "scenario_count": len(transcript),
    "scenarios": scenario_html,
}

out_path = os.path.join(pages_dir, "index.html")
with open(out_path, "w") as f:
    f.write(html)
print("Gallery: {} bytes, {} scenarios, {} elements".format(len(html), len(transcript), total_elements))
