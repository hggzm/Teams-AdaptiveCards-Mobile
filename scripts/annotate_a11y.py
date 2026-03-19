#!/usr/bin/env python3
"""
Annotate a11y screenshots with numbered accessibility element overlays
and generate TTS narration audio from the accessibility tree.

Usage: python3 annotate_a11y.py <screenshots_dir> <trees_dir> <output_dir>

For each screenshot + matching XML tree:
1. Parse XML for nodes with text/content-desc and bounds
2. Draw numbered rectangles on the screenshot (like RocketSim's VoiceOver Navigator)
3. Generate a reading order transcript
4. Generate TTS audio via espeak-ng
5. If video exists, merge TTS audio track with ffmpeg

Requires: Pillow (PIL), espeak-ng, ffmpeg
"""
import os
import sys
import re
import subprocess
import json
import xml.etree.ElementTree as ET
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("WARNING: Pillow not installed, annotated screenshots will be skipped")
    Image = None

screenshots_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-screenshots"
trees_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/a11y-trees"
output_dir = sys.argv[3] if len(sys.argv) > 3 else "/tmp/a11y-annotated"

os.makedirs(output_dir, exist_ok=True)


def parse_bounds(bounds_str):
    """Parse '[x1,y1][x2,y2]' into (x1, y1, x2, y2)."""
    m = re.findall(r'\[(\d+),(\d+)\]', bounds_str)
    if len(m) == 2:
        return (int(m[0][0]), int(m[0][1]), int(m[1][0]), int(m[1][1]))
    return None


def extract_a11y_nodes(data_path):
    """Extract accessibility nodes from either XML dump or logcat-extracted txt file.

    Supports two formats:
    - XML: standard UiDevice dumpWindowHierarchy output
    - TXT: logcat-extracted format with lines like: index|label|[x1,y1][x2,y2]
    """
    if not os.path.exists(data_path):
        return []

    nodes = []

    # Try TXT format first (logcat extraction)
    if data_path.endswith('.txt'):
        try:
            with open(data_path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    parts = line.split('|')
                    if len(parts) >= 3:
                        # Format: index|label|[x1,y1][x2,y2]
                        idx = parts[0]
                        label = parts[1]
                        bounds_str = parts[2]
                    elif len(parts) == 2:
                        # Format: label|[x1,y1][x2,y2]
                        label = parts[0]
                        bounds_str = parts[1]
                    else:
                        continue

                    rect = parse_bounds(bounds_str)
                    if rect and label:
                        w = rect[2] - rect[0]
                        h = rect[3] - rect[1]
                        if w > 5 and h > 5:
                            nodes.append({
                                "label": label,
                                "class": "View",
                                "bounds": rect,
                                "focusable": True,
                                "clickable": False,
                            })
        except Exception as e:
            print("  WARNING: Could not parse TXT: {} ({})".format(data_path, e))
        return nodes

    # Fall back to XML format
    try:
        tree = ET.parse(data_path)
    except ET.ParseError:
        print("  WARNING: Could not parse XML: {}".format(data_path))
        return []

    root = tree.getroot()
    for node in root.iter("node"):
        text = node.get("text", "").strip()
        desc = node.get("content-desc", "").strip()
        bounds = node.get("bounds", "")
        cls = node.get("class", "").split(".")[-1]
        focusable = node.get("focusable", "false") == "true"
        clickable = node.get("clickable", "false") == "true"
        pkg = node.get("package", "")

        if "systemui" in pkg.lower() or "launcher" in pkg.lower():
            continue

        label = desc if desc else text
        if not label:
            continue

        rect = parse_bounds(bounds)
        if not rect:
            continue

        # Skip tiny elements (likely decorators)
        w = rect[2] - rect[0]
        h = rect[3] - rect[1]
        if w < 5 or h < 5:
            continue

        nodes.append({
            "label": label,
            "class": cls,
            "bounds": rect,
            "focusable": focusable,
            "clickable": clickable,
        })

    return nodes


def annotate_screenshot(img_path, nodes, output_path):
    """Draw numbered overlay rectangles on screenshot."""
    if Image is None:
        return False

    img = Image.open(img_path).convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    # Colors for overlay
    FOCUS_COLOR = (0, 200, 0, 100)  # Green semi-transparent fill
    BORDER_COLOR = (0, 220, 0, 255)  # Green border
    NUMBER_BG = (0, 150, 0, 220)  # Dark green badge
    TEXT_COLOR = (255, 255, 255, 255)

    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 28)
        small_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
    except (OSError, IOError):
        font = ImageFont.load_default()
        small_font = font

    for i, node in enumerate(nodes):
        x1, y1, x2, y2 = node["bounds"]
        num = i + 1

        # Draw semi-transparent fill
        draw.rectangle([x1, y1, x2, y2], fill=FOCUS_COLOR, outline=BORDER_COLOR, width=3)

        # Draw number badge
        badge_size = 36
        badge_x = x1
        badge_y = max(0, y1 - badge_size)
        draw.ellipse(
            [badge_x, badge_y, badge_x + badge_size, badge_y + badge_size],
            fill=NUMBER_BG
        )
        # Center number in badge
        num_text = str(num)
        draw.text(
            (badge_x + badge_size // 2, badge_y + badge_size // 2),
            num_text, fill=TEXT_COLOR, font=font, anchor="mm"
        )

        # Draw label text below the element
        label = node["label"][:40]
        if len(node["label"]) > 40:
            label += "..."
        label_y = min(y2 + 2, img.size[1] - 20)
        draw.text(
            (x1 + 4, label_y),
            label, fill=(255, 255, 255, 200), font=small_font
        )

    # Composite overlay onto original
    result = Image.alpha_composite(img, overlay)
    result.convert("RGB").save(output_path)
    return True


def generate_tts_audio(transcript, output_path):
    """Generate TTS audio from transcript using espeak-ng."""
    # Build full narration text
    narration = ". ".join(
        "Element {}: {}. {}".format(
            i + 1,
            entry["label"],
            entry["class"]
        )
        for i, entry in enumerate(transcript)
    )

    if not narration:
        return False

    try:
        result = subprocess.run(
            ["espeak-ng", "-v", "en", "-s", "140", "-w", output_path, narration],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and os.path.exists(output_path) and os.path.getsize(output_path) > 100:
            print("  TTS audio: {} ({} bytes)".format(output_path, os.path.getsize(output_path)))
            return True
        else:
            print("  TTS failed: {}".format(result.stderr[:200]))
            return False
    except FileNotFoundError:
        print("  espeak-ng not found, skipping TTS")
        return False
    except subprocess.TimeoutExpired:
        print("  TTS timed out")
        return False


def merge_audio_with_video(video_path, audio_path, output_path):
    """Merge TTS audio track with video using ffmpeg."""
    try:
        result = subprocess.run([
            "ffmpeg", "-y",
            "-i", video_path,
            "-i", audio_path,
            "-c:v", "copy",
            "-c:a", "aac",
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-shortest",
            output_path
        ], capture_output=True, text=True, timeout=60)
        if result.returncode == 0 and os.path.exists(output_path):
            sz = os.path.getsize(output_path)
            print("  Merged video+audio: {} ({:.1f} MB)".format(output_path, sz / 1048576))
            return True
        else:
            print("  ffmpeg merge failed: {}".format(result.stderr[:200]))
            return False
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        print("  ffmpeg error: {}".format(e))
        return False


# ── Main ──

SCENARIOS = [
    "showcard_collapsed", "showcard_expanded", "showcard_collapsed_again",
    "validation_empty_form", "validation_error_visible",
    "toggle_visibility_hidden", "toggle_visibility_revealed",
    "activity_showcard_buttons", "activity_showcard_expanded",
]

all_transcripts = []
annotated_count = 0
tts_segments = []

for scenario in SCENARIOS:
    prefix = "android_a11y_" + scenario
    img_path = os.path.join(screenshots_dir, prefix + ".png")
    # Try .txt (logcat-extracted), then .xml
    data_path = None
    txt_path = os.path.join(trees_dir, prefix + ".txt")
    xml_path = os.path.join(trees_dir, prefix + ".xml")
    if os.path.exists(txt_path) and os.path.getsize(txt_path) > 10:
        data_path = txt_path
    elif os.path.exists(xml_path):
        data_path = xml_path

    if not os.path.exists(img_path):
        print("SKIP {}: no screenshot".format(scenario))
        continue

    print("Processing: {}".format(scenario))

    # Parse a11y tree if available
    nodes = []
    if data_path:
        nodes = extract_a11y_nodes(data_path)
        print("  A11y nodes: {} elements from {}".format(len(nodes), os.path.basename(data_path)))
    else:
        print("  No a11y data for this scenario")

    # Create annotated screenshot
    annotated_path = os.path.join(output_dir, prefix + "_annotated.png")
    if nodes and annotate_screenshot(img_path, nodes, annotated_path):
        annotated_count += 1
        print("  Annotated: {}".format(annotated_path))
    else:
        # Copy original if no annotation possible
        import shutil
        shutil.copy2(img_path, os.path.join(output_dir, prefix + ".png"))

    # Build transcript for this scenario
    transcript_entry = {
        "scenario": scenario,
        "nodes": [
            {"index": i + 1, "label": n["label"], "class": n["class"],
             "bounds": list(n["bounds"]), "focusable": n["focusable"]}
            for i, n in enumerate(nodes)
        ]
    }
    all_transcripts.append(transcript_entry)

    # Generate per-scenario TTS
    if nodes:
        tts_path = os.path.join(output_dir, prefix + "_narration.wav")
        if generate_tts_audio(nodes, tts_path):
            tts_segments.append(tts_path)

# Save transcript JSON
transcript_path = os.path.join(output_dir, "a11y_transcript.json")
with open(transcript_path, "w") as f:
    json.dump(all_transcripts, f, indent=2)
print("\nTranscript: {} scenarios, {} total nodes".format(
    len(all_transcripts),
    sum(len(t["nodes"]) for t in all_transcripts)
))

# Concatenate TTS segments and merge with video
if tts_segments:
    # Concatenate all WAV segments
    concat_list = os.path.join(output_dir, "concat.txt")
    with open(concat_list, "w") as f:
        for seg in tts_segments:
            f.write("file '{}'\n".format(seg))

    combined_audio = os.path.join(output_dir, "combined_narration.wav")
    try:
        subprocess.run([
            "ffmpeg", "-y", "-f", "concat", "-safe", "0",
            "-i", concat_list, "-c", "copy", combined_audio
        ], capture_output=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        print("ffmpeg not found for WAV concat, skipping narrated video")
        combined_audio = None

    # Find the video file
    video_candidates = [
        os.path.join(screenshots_dir, "android_a11y_talkback_recording.mp4"),
        os.path.join(output_dir, "..", "android_a11y_talkback_recording.mp4"),
    ]
    video_path = None
    for vc in video_candidates:
        if os.path.exists(vc):
            video_path = vc
            break

    if video_path and combined_audio and os.path.exists(combined_audio):
        narrated_video = os.path.join(output_dir, "android_a11y_talkback_narrated.mp4")
        merge_audio_with_video(video_path, combined_audio, narrated_video)

    # Cleanup temp files
    for seg in tts_segments:
        os.remove(seg) if os.path.exists(seg) else None
    os.remove(concat_list) if os.path.exists(concat_list) else None
    os.remove(combined_audio) if os.path.exists(combined_audio) else None

print("\nDone: {} annotated screenshots, {} TTS segments".format(
    annotated_count, len(tts_segments)
))
