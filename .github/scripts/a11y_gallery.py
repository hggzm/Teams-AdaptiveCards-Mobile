#!/usr/bin/env python3
"""Generate HTML gallery page for GitHub Pages deployment."""
import json, os, sys

pages_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-pages"
transcript_path = os.path.join(pages_dir, "transcript.json")
validation_path = os.path.join(pages_dir, "validation.json")

transcript = {}
validation = {}
if os.path.exists(transcript_path):
    with open(transcript_path) as f:
        transcript = json.load(f)
if os.path.exists(validation_path):
    with open(validation_path) as f:
        validation = json.load(f)

# Build transcript table rows
rows = ""
for entry in transcript.get("transcript", []):
    exp = entry.get("expected", {})
    scenario = exp.get("scenario", "")
    anns = exp.get("announcements", [])
    ann_html = ""
    for ann in anns:
        if ann.get("hidden"):
            ann_html += '<div class="ann hidden">\xf0\x9f\x94\x87 {} \xe2\x80\x94 hidden</div>'.format(ann["element"]).encode().decode('utf-8', errors='replace')
        else:
            label = ann.get("label", "")
            value = ann.get("value", "")
            traits = ann.get("traits", "")
            text = '&quot;{}'.format(label)
            if value:
                text += ", {}".format(value)
            text += '&quot; ({})'.format(traits)
            ann_html += '<div class="ann">&#x1F50A; {}</div>'.format(text)
        if ann.get("note"):
            ann_html += '<div class="note">&#x2139;&#xFE0F; {}</div>'.format(ann["note"])

    result_class = "pass" if entry["result"] == "passed" else "fail"
    ts_str = "{:.1f}".format(entry["timestamp_sec"])
    result_upper = entry["result"].upper()
    test_name = entry["test_name"]
    rows += '<tr>'
    rows += '<td class="ts">{}s</td>'.format(ts_str)
    rows += '<td><span class="badge badge-{}">'.format(result_class) + result_upper + '</span></td>'
    rows += '<td><strong>{}</strong><br><small>{}</small></td>'.format(scenario, test_name)
    rows += '<td>{}</td>'.format(ann_html)
    rows += '</tr>\n'

verdict = validation.get("verdict", "N/A")
checks = validation.get("passed", 0)
verdict_class = "pass" if verdict == "PASS" else "fail"

html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>A11y Screenshot &amp; VoiceOver Gallery</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0d1117; color: #c9d1d9; padding: 2rem; }
    h1 { color: #58a6ff; margin-bottom: 0.5rem; }
    .meta { color: #8b949e; margin-bottom: 2rem; font-size: 0.9rem; }
    h2 { color: #f0f6fc; margin: 2rem 0 1rem; border-bottom: 1px solid #30363d; padding-bottom: 0.5rem; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); gap: 1.5rem; margin: 1rem 0; }
    .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; overflow: hidden; }
    .card img { width: 100%%; display: block; cursor: pointer; }
    .card .label { padding: 0.75rem 1rem; font-size: 0.85rem; color: #8b949e; }
    .card .label .name { color: #c9d1d9; font-weight: 600; display: block; margin-bottom: 0.25rem; }
    .before-after { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin: 1rem 0; }
    .before-after .card { position: relative; }
    .before-after .card::before { position: absolute; top: 8px; left: 8px; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: 700; z-index: 1; }
    .before-after .before::before { content: 'BEFORE'; background: #da3633; color: white; }
    .before-after .after::before { content: 'AFTER'; background: #238636; color: white; }
    video { width: 100%%; max-width: 700px; border-radius: 8px; border: 1px solid #30363d; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
    .badge-pass { background: #238636; color: white; }
    .badge-fail { background: #da3633; color: white; }
    .badge-info { background: #1f6feb; color: white; }
    table.transcript { width: 100%%; border-collapse: collapse; margin: 1rem 0; }
    table.transcript th { background: #161b22; color: #8b949e; padding: 10px; text-align: left; border-bottom: 2px solid #30363d; }
    table.transcript td { padding: 10px; border-bottom: 1px solid #21262d; vertical-align: top; }
    table.transcript .ts { font-family: 'SF Mono', monospace; color: #58a6ff; white-space: nowrap; }
    .ann { margin: 4px 0; padding: 4px 8px; background: #1c2128; border-radius: 4px; font-size: 0.85rem; }
    .ann.hidden { opacity: 0.6; }
    .note { font-size: 0.8rem; color: #8b949e; margin: 2px 0 2px 20px; font-style: italic; }
    .fullscreen-overlay { display: none; position: fixed; top: 0; left: 0; width: 100%%; height: 100%%; background: rgba(0,0,0,0.9); z-index: 1000; cursor: pointer; justify-content: center; align-items: center; }
    .fullscreen-overlay img { max-width: 95%%; max-height: 95%%; object-fit: contain; }
    .fullscreen-overlay.active { display: flex; }
    .validation-box { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 1.5rem; margin: 1rem 0; }
  </style>
</head>
<body>
  <h1>iOS Accessibility Screenshot &amp; VoiceOver Gallery</h1>
  <div class="meta">
    <span class="badge badge-%(verdict_class)s">TRANSCRIPT: %(verdict)s</span>
    <span class="badge badge-info">%(checks)s CHECKS PASSED</span>
  </div>
  <h2>&#x1F3A5; VoiceOver Recording with Narration</h2>
  <video controls preload="metadata"><source src="voiceover_demo.mp4" type="video/mp4">Your browser does not support video.</video>
  <p style="color: #8b949e; margin-top: 0.5rem;">Screen recording of snapshot test execution with synthesized VoiceOver narration.</p>
  <h2>&#x1F4CB; Timed VoiceOver Transcript</h2>
  <p style="color: #8b949e; margin-bottom: 1rem;">Compare timestamps with the video to verify announcements match interaction timing.</p>
  <table class="transcript"><thead><tr><th>Time</th><th>Result</th><th>Scenario</th><th>VoiceOver Announcements</th></tr></thead><tbody>
%(transcript_rows)s
  </tbody></table>
  <h2>Scenario 1: ShowCard Expand/Collapse <small>(PR #660)</small></h2>
  <div class="before-after">
    <div class="card before"><img src="showcard_expand_before_iPhone15Pro_light.png" alt="collapsed" onclick="showFull(this)"><div class="label"><span class="name">showcard_expand_before</span>accessibilityValue = "collapsed"</div></div>
    <div class="card after"><img src="showcard_expand_after_iPhone15Pro_light.png" alt="expanded" onclick="showFull(this)"><div class="label"><span class="name">showcard_expand_after</span>accessibilityValue = "card expanded"</div></div>
  </div>
  <h2>Scenario 2: ShowCard Dismiss <small>(PR #660)</small></h2>
  <div class="grid"><div class="card"><img src="showcard_dismiss_after_iPhone15Pro_light.png" alt="dismissed" onclick="showFull(this)"><div class="label"><span class="name">showcard_dismiss_after</span>Content hidden, focus returns to button</div></div></div>
  <h2>Scenario 3: ToggleVisibility <small>(PR #661)</small></h2>
  <div class="before-after">
    <div class="card before"><img src="togglevisibility_before_iPhone15Pro_light.png" alt="hidden" onclick="showFull(this)"><div class="label"><span class="name">togglevisibility_before</span>History rows hidden</div></div>
    <div class="card after"><img src="togglevisibility_after_iPhone15Pro_light.png" alt="revealed" onclick="showFull(this)"><div class="label"><span class="name">togglevisibility_after</span>History rows visible</div></div>
  </div>
  <h2>Scenario 4: ActivityUpdate ShowCard <small>(PR #660)</small></h2>
  <div class="before-after">
    <div class="card before"><img src="activityupdate_showcard_before_iPhone15Pro_light.png" alt="collapsed" onclick="showFull(this)"><div class="label"><span class="name">activityupdate_showcard_before</span>accessibilityValue = "collapsed"</div></div>
    <div class="card after"><img src="activityupdate_showcard_after_iPhone15Pro_light.png" alt="expanded" onclick="showFull(this)"><div class="label"><span class="name">activityupdate_showcard_after</span>accessibilityValue = "card expanded"</div></div>
  </div>
  <h2>&#x1F4C4; Raw Transcript</h2>
  <div class="validation-box"><p>Download: <a href="transcript.json" style="color:#58a6ff">transcript.json</a> | <a href="transcript.txt" style="color:#58a6ff">transcript.txt</a> | <a href="validation.json" style="color:#58a6ff">validation.json</a></p></div>
  <div class="fullscreen-overlay" id="overlay" onclick="this.classList.remove('active')"><img id="overlay-img" src="" alt="Full size"></div>
  <script>function showFull(img){document.getElementById('overlay-img').src=img.src;document.getElementById('overlay').classList.add('active');}</script>
</body>
</html>"""

html = html % {"verdict_class": verdict_class, "verdict": verdict,
               "checks": checks, "transcript_rows": rows}

with open(os.path.join(pages_dir, "index.html"), "w") as f:
    f.write(html)
print("Gallery HTML: {} bytes".format(len(html)))
