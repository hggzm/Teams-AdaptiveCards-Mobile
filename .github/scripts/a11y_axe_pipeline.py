#!/usr/bin/env python3
"""
Pipeline that reads XCUITest-dumped accessibility trees and draws overlays.

The XCUITest (A11yOverlayUITests) dumps the a11y tree to /tmp/a11y-xcui/
as JSON files with real element frames. This script:
1. Records video via AXe during XCUITest execution
2. Reads the dumped a11y tree JSON files
3. Draws numbered bounding boxes onto the screenshots
4. Generates VoiceOver narration from the real element labels

Usage:
  python3 a11y_axe_pipeline.py <sim_udid> <output_dir>
"""
import subprocess, json, os, sys, time, shutil
from pathlib import Path

UDID = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SIM_UDID", "")
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "/tmp/axe-output"
XCUI_DIR = "/tmp/a11y-xcui"
SCREEN_W = 393
SCREEN_H = 852

os.makedirs(OUT_DIR, exist_ok=True)


def run_cmd(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except Exception as e:
        return -1, "", str(e)


def draw_overlays(screenshot_path, elements, output_path):
    """Draw numbered bounding boxes onto a screenshot."""
    if not os.path.exists(screenshot_path) or not elements:
        return False

    rc, stdout, _ = run_cmd([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0",
        screenshot_path
    ])
    scale = 2.0
    if rc == 0 and stdout.strip():
        parts = stdout.strip().split(",")
        if parts:
            scale = int(parts[0]) / SCREEN_W

    colors = [
        "0x007AFF", "0x34C759", "0xFF9500", "0xFF3B30", "0xAF52DE",
        "0x5856D6", "0xFF2D55", "0x00C7BE", "0x30B0C7", "0xFFCC00",
    ]

    filters = []
    for i, elem in enumerate(elements[:25]):
        fr = elem.get("frame", {})
        x = int(fr.get("x", 0) * scale)
        y = int(fr.get("y", 0) * scale)
        w = int(fr.get("width", 50) * scale)
        h = int(fr.get("height", 30) * scale)

        if w < 5 or h < 5:
            continue

        color = colors[i % len(colors)]
        label = elem.get("label", "")
        role = elem.get("role", "")

        filters.append("drawbox=x={}:y={}:w={}:h={}:color={}@0.5:t=4".format(
            x, y, w, h, color))
        filters.append(
            "drawtext=text='{}':fontsize={}:fontcolor=white"
            ":borderw=3:bordercolor={}:x={}:y={}".format(
                i + 1, int(20 * scale), color, x + 4, y + 2))

        safe = label.replace("'", "").replace(":", " ").replace("\\", "")[:20]
        tag = "[{}] {}".format(role[:6], safe).replace("'", "").replace(":", " ")
        ty = min(y + h + 2, int(SCREEN_H * scale) - int(14 * scale))
        filters.append(
            "drawtext=text='{}':fontsize={}:fontcolor=white"
            ":borderw=1:bordercolor=black:x={}:y={}".format(
                tag, int(11 * scale), x, ty))

    if not filters:
        return False

    rc, _, stderr = run_cmd([
        "ffmpeg", "-y", "-i", screenshot_path,
        "-vf", ",".join(filters), output_path
    ], timeout=30)

    return rc == 0


print("=" * 60)
print("XCUITest A11y Overlay Pipeline")
print("UDID: {}".format(UDID))
print("=" * 60)

# 1. Start AXe video recording
video_path = os.path.join(OUT_DIR, "raw_recording.mp4")
rec_proc = subprocess.Popen(
    ["axe", "record-video", "--udid", UDID, "--fps", "15", "--output", video_path],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
time.sleep(2)
print("[REC] Recording PID: {}".format(rec_proc.pid))

# 2. Clean a11y dump dir
shutil.rmtree(XCUI_DIR, ignore_errors=True)
os.makedirs(XCUI_DIR, exist_ok=True)

# 3. Run XCUITests that dump a11y trees
print("[TEST] Running A11yOverlayUITests...")
start_time = time.time()

rc, stdout, stderr = run_cmd([
    "xcodebuild", "test-without-building",
    "-workspace", "source/ios/AdaptiveCards/AdaptiveCards.xcworkspace",
    "-scheme", "ADCIOSVisualizer",
    "-sdk", "iphonesimulator",
    "-destination", "platform=iOS Simulator,id={}".format(UDID),
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yDumpActivityUpdateShowCard",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yDumpExpenseReportCard",
    "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO",
], timeout=300)

test_dur = time.time() - start_time
print("[TEST] Completed in {:.1f}s (exit: {})".format(test_dur, rc))

with open(os.path.join(OUT_DIR, "xcuitest.log"), "w") as f:
    f.write(stdout + "\n--- STDERR ---\n" + stderr)

# Count passes
passed = stdout.count("passed")
failed = stdout.count("failed")
print("[TEST] Passed: {}, Failed: {}".format(passed, failed))

# 4. Stop recording
print("[REC] Stopping recording...")
time.sleep(2)
rec_proc.send_signal(2)
try:
    rec_proc.wait(timeout=15)
except:
    rec_proc.kill()
time.sleep(2)

if os.path.exists(video_path):
    shutil.copy2(video_path, os.path.join(OUT_DIR, "voiceover_demo.mp4"))
    print("[REC] Recording: {} bytes".format(os.path.getsize(video_path)))

# 5. Read XCUITest-dumped a11y trees
print("\n" + "=" * 60)
print("Reading XCUITest a11y tree dumps from {}".format(XCUI_DIR))
print("=" * 60)

dumps = []
for f in sorted(os.listdir(XCUI_DIR)):
    src = os.path.join(XCUI_DIR, f)
    dst = os.path.join(OUT_DIR, f)
    shutil.copy2(src, dst)
    if f.endswith("_elements.json"):
        with open(src) as fh:
            elements = json.load(fh)
        name = f.replace("_elements.json", "")
        dumps.append({"name": name, "elements": elements, "count": len(elements)})
        print("  {} — {} elements".format(name, len(elements)))
        for i, e in enumerate(elements[:8]):
            fr = e.get("frame", {})
            print("    {:2d}. [{}] {} = {} ({},{} {}x{})".format(
                i + 1, e.get("role", "")[:8], e.get("label", "")[:25],
                (e.get("value", "") or "")[:15],
                int(fr.get("x", 0)), int(fr.get("y", 0)),
                int(fr.get("width", 0)), int(fr.get("height", 0))))
        if len(elements) > 8:
            print("    ... and {} more".format(len(elements) - 8))

# 6. Draw overlays on screenshots
print("\n" + "=" * 60)
print("Drawing accessibility overlays")
print("=" * 60)

annotated_dir = os.path.join(OUT_DIR, "annotated")
os.makedirs(annotated_dir, exist_ok=True)
annotated_count = 0

for dump in dumps:
    name = dump["name"]
    elements = dump["elements"]
    screenshot = os.path.join(OUT_DIR, "{}.png".format(name))

    if os.path.exists(screenshot) and elements:
        annotated_path = os.path.join(annotated_dir, "annotated_{}.png".format(name))
        if draw_overlays(screenshot, elements, annotated_path):
            annotated_count += 1
            print("  ANNOTATED: {} ({} elements)".format(name, len(elements)))
        else:
            print("  DRAW FAILED: {}".format(name))
    else:
        if not os.path.exists(screenshot):
            print("  NO SCREENSHOT: {} (expected at {})".format(name, screenshot))
        else:
            print("  NO ELEMENTS: {}".format(name))

# 7. Generate narration
print("\n" + "=" * 60)
print("Generating VoiceOver narration")
print("=" * 60)

narr_count = 0
for dump in dumps:
    elements = dump["elements"]
    lines = []
    for e in elements[:10]:
        speech = e.get("label", "")
        val = e.get("value", "")
        role = e.get("role", "")
        if not speech:
            continue
        if val:
            speech += ", " + val
        speech += ". " + role + "."
        lines.append(speech)
    if lines:
        text = " ".join(lines)
        narr_path = os.path.join(OUT_DIR, "narr_{}.aiff".format(dump["name"]))
        rc, _, _ = run_cmd(
            ["say", "-v", "Samantha", "-r", "180", "-o", narr_path, text], timeout=15)
        if rc == 0:
            narr_count += 1
            print("  Narration {}: {} bytes".format(dump["name"], os.path.getsize(narr_path)))

# 8. Metadata
metadata = {
    "test_duration_sec": round(test_dur, 1),
    "tests_passed": passed,
    "tests_failed": failed,
    "a11y_dumps": [{"name": d["name"], "element_count": d["count"]} for d in dumps],
    "annotated_screenshots": annotated_count,
    "narration_segments": narr_count,
    "video_size": os.path.getsize(video_path) if os.path.exists(video_path) else 0,
}
with open(os.path.join(OUT_DIR, "timeline.json"), "w") as f:
    json.dump(metadata, f, indent=2)

print("\n" + "=" * 60)
print("Pipeline complete")
print("  A11y tree dumps: {}".format(len(dumps)))
print("  Annotated screenshots: {}".format(annotated_count))
print("  Narrations: {}".format(narr_count))
print("  Video: {} bytes".format(
    os.path.getsize(video_path) if os.path.exists(video_path) else 0))
print("=" * 60)
sys.exit(0)
