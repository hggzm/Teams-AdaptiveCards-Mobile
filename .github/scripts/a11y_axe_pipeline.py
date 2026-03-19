#!/usr/bin/env python3
"""
Option 2: Parallel describe-ui capture during XCUITest execution.

Runs axe describe-ui in a loop every 2 seconds while XCUITests drive
real card interactions. The describe-ui captures happen while the app
is alive and showing card content.

After tests complete, finds the richest a11y tree snapshots (most elements),
pairs them with screenshots, and draws overlays.

Usage:
  python3 a11y_axe_pipeline.py <sim_udid> <output_dir>
"""
import subprocess, json, os, sys, time, shutil, threading, hashlib
from pathlib import Path

UDID = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SIM_UDID", "")
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "/tmp/axe-output"
os.makedirs(OUT_DIR, exist_ok=True)

SCREEN_W = 393
SCREEN_H = 852


def run_cmd(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except Exception as e:
        return -1, "", str(e)


def parse_elements(tree_data):
    """Recursively extract all labeled elements with frames from an a11y tree."""
    elements = []

    def walk(node, depth=0):
        label = node.get("AXLabel") or ""
        value = node.get("AXValue")
        role = node.get("role_description") or node.get("role", "")
        frame = node.get("frame", {})
        uid = node.get("AXUniqueId") or ""

        # Keep elements that have a label and aren't the root app/window
        if label and role not in ("application", "window", ""):
            w = frame.get("width", frame.get("w", 0))
            h = frame.get("height", frame.get("h", 0))
            # Skip elements that span the full screen (containers)
            if w < SCREEN_W * 0.9 or h < SCREEN_H * 0.5:
                elements.append({
                    "label": label,
                    "value": value if value else "",
                    "role": role,
                    "frame": frame,
                    "uid": uid,
                    "depth": depth,
                    "help": node.get("help") or "",
                })

        for child in node.get("children", []):
            walk(child, depth + 1)

    if isinstance(tree_data, list):
        for node in tree_data:
            walk(node)
    elif isinstance(tree_data, dict):
        walk(tree_data)

    # Sort by position (reading order)
    elements.sort(key=lambda e: (e["frame"].get("y", 0), e["frame"].get("x", 0)))
    return elements


# ═══════════════════════════════════════════════════════════════
# Background describe-ui capture thread
# ═══════════════════════════════════════════════════════════════

capture_running = True
captures = []  # [{timestamp, elements, raw_json_path}]
capture_lock = threading.Lock()


def describe_ui_loop():
    """Run describe-ui every 2 seconds in background, save results."""
    idx = 0
    while capture_running:
        ts = time.time()
        rc, stdout, stderr = run_cmd(
            ["axe", "describe-ui", "--udid", UDID], timeout=8)

        if rc == 0 and stdout.strip():
            try:
                tree = json.loads(stdout)
                elements = parse_elements(tree)

                if elements:  # Only save non-empty captures
                    snap_name = "snap_{:03d}".format(idx)
                    raw_path = os.path.join(OUT_DIR, "{}_tree.json".format(snap_name))
                    elem_path = os.path.join(OUT_DIR, "{}_elements.json".format(snap_name))

                    with open(raw_path, "w") as f:
                        f.write(stdout)
                    with open(elem_path, "w") as f:
                        json.dump(elements, f, indent=2)

                    with capture_lock:
                        captures.append({
                            "timestamp": round(ts, 1),
                            "idx": idx,
                            "name": snap_name,
                            "element_count": len(elements),
                            "elements_path": elem_path,
                        })

                    idx += 1
            except json.JSONDecodeError:
                pass

        # Wait 2 seconds between captures
        elapsed = time.time() - ts
        sleep_time = max(0.5, 2.0 - elapsed)
        time.sleep(sleep_time)


def draw_overlays(screenshot_path, elements, output_path):
    """Draw numbered bounding boxes onto a screenshot using ffmpeg."""
    if not os.path.exists(screenshot_path) or not elements:
        return False

    # Detect image scale
    rc, stdout, _ = run_cmd([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height", "-of", "csv=p=0",
        screenshot_path
    ])
    scale = 2.0
    if rc == 0 and stdout.strip():
        parts = stdout.strip().split(",")
        if len(parts) >= 1:
            scale = int(parts[0]) / SCREEN_W

    colors = [
        "0x007AFF", "0x34C759", "0xFF9500", "0xFF3B30", "0xAF52DE",
        "0x5856D6", "0xFF2D55", "0x00C7BE", "0x30B0C7", "0xFFCC00",
        "0x64D2FF", "0xFF6482", "0xBF5AF2", "0x32D74B", "0xFF6961"
    ]

    filters = []
    for i, elem in enumerate(elements[:20]):
        fr = elem.get("frame", {})
        x = int(fr.get("x", 0) * scale)
        y = int(fr.get("y", 0) * scale)
        w = int(fr.get("width", fr.get("w", 50)) * scale)
        h = int(fr.get("height", fr.get("h", 30)) * scale)
        color = colors[i % len(colors)]
        label = elem.get("label", "")
        role = elem.get("role", "")[:6]

        if w < 5 or h < 5:
            continue

        # Bounding box
        filters.append(
            "drawbox=x={}:y={}:w={}:h={}:color={}@0.5:t=4".format(x, y, w, h, color))
        # Index number
        filters.append(
            "drawtext=text='{}':fontsize={}:fontcolor=white"
            ":borderw=3:bordercolor={}:x={}:y={}".format(
                i + 1, int(20 * scale), color, x + 4, y + 2))
        # Label
        safe = label.replace("'", "").replace(":", " ").replace("\\", "")[:20]
        tag = "[{}] {}".format(role, safe).replace("'", "").replace(":", " ")
        ty = min(y + h + 2, int(SCREEN_H * scale) - int(14 * scale))
        filters.append(
            "drawtext=text='{}':fontsize={}:fontcolor=white"
            ":borderw=1:bordercolor=black:x={}:y={}".format(
                tag, int(11 * scale), x, ty))

    if not filters:
        shutil.copy2(screenshot_path, output_path)
        return False

    rc, _, stderr = run_cmd([
        "ffmpeg", "-y", "-i", screenshot_path,
        "-vf", ",".join(filters), output_path
    ], timeout=30)

    return rc == 0


# ═══════════════════════════════════════════════════════════════
# Main pipeline
# ═══════════════════════════════════════════════════════════════

print("=" * 60)
print("Option 2: Parallel describe-ui during XCUITests")
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

# 2. Start background describe-ui capture thread
print("[A11Y] Starting background a11y capture loop...")
capture_thread = threading.Thread(target=describe_ui_loop, daemon=True)
capture_thread.start()

# 3. Take a pre-test screenshot
axe_preshot = os.path.join(OUT_DIR, "pre_test.png")
run_cmd(["axe", "screenshot", "--output", axe_preshot, "--udid", UDID])
print("[SHOT] Pre-test screenshot")

# 4. Run XCUITests (they drive real card interactions)
print("\n[TEST] Running XCUITests...")
start_time = time.time()

rc, stdout, stderr = run_cmd([
    "xcodebuild", "test-without-building",
    "-workspace", "source/ios/AdaptiveCards/AdaptiveCards.xcworkspace",
    "-scheme", "ADCIOSVisualizer",
    "-sdk", "iphonesimulator",
    "-destination", "platform=iOS Simulator,id={}".format(UDID),
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testSmokeTestActivityUpdateComment",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testSmokeTestActivityUpdateDate",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testFocusOnValidationFailure",
    "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO",
], timeout=300)

test_duration = time.time() - start_time
print("[TEST] XCUITests completed in {:.1f}s (exit: {})".format(test_duration, rc))

# Save test log
with open(os.path.join(OUT_DIR, "xcuitest.log"), "w") as f:
    f.write(stdout)
    f.write("\n--- STDERR ---\n")
    f.write(stderr)

# Parse test results
passed = stdout.count("passed")
failed = stdout.count("failed")
print("[TEST] Passed: {}, Failed: {}".format(passed, failed))

# 5. Take post-test screenshots
for i in range(3):
    time.sleep(1)
    shot_path = os.path.join(OUT_DIR, "post_test_{}.png".format(i))
    run_cmd(["axe", "screenshot", "--output", shot_path, "--udid", UDID])

# 6. Stop background capture
print("\n[A11Y] Stopping background capture...")
capture_running = False
capture_thread.join(timeout=10)
print("[A11Y] Captured {} a11y snapshots during tests".format(len(captures)))

# 7. Stop video recording
print("[REC] Stopping recording...")
rec_proc.send_signal(2)
try:
    rec_proc.wait(timeout=15)
except:
    rec_proc.kill()
time.sleep(2)

if os.path.exists(video_path):
    sz = os.path.getsize(video_path)
    print("[REC] Recording: {} bytes".format(sz))
    shutil.copy2(video_path, os.path.join(OUT_DIR, "voiceover_demo.mp4"))

# ═══════════════════════════════════════════════════════════════
# Post-processing: find richest captures and draw overlays
# ═══════════════════════════════════════════════════════════════

print("\n" + "=" * 60)
print("Post-processing: finding richest accessibility captures")
print("=" * 60)

annotated_dir = os.path.join(OUT_DIR, "annotated")
os.makedirs(annotated_dir, exist_ok=True)

# Sort captures by element count (most elements = card content visible)
with capture_lock:
    sorted_captures = sorted(captures, key=lambda c: c["element_count"], reverse=True)

# Find unique captures (different element sets)
seen_counts = set()
best_captures = []
for cap in sorted_captures:
    count = cap["element_count"]
    if count not in seen_counts and count > 3:
        seen_counts.add(count)
        best_captures.append(cap)
    if len(best_captures) >= 5:
        break

print("Best {} captures (by element richness):".format(len(best_captures)))
for cap in best_captures:
    print("  {} — {} elements at {:.1f}s".format(
        cap["name"], cap["element_count"],
        cap["timestamp"] - (captures[0]["timestamp"] if captures else 0)))

# For each best capture, take a screenshot at the nearest time and draw overlays
# Since we can't go back in time, use the post-test screenshots or take new ones
# Actually the video has the frames — extract frames at capture timestamps
if best_captures and os.path.exists(video_path):
    base_time = captures[0]["timestamp"] if captures else start_time
    for cap in best_captures:
        name = cap["name"]
        elem_path = cap["elements_path"]
        relative_ts = cap["timestamp"] - base_time

        # Extract frame from video at this timestamp
        frame_path = os.path.join(OUT_DIR, "{}_frame.png".format(name))
        run_cmd([
            "ffmpeg", "-y", "-ss", str(max(0, relative_ts)),
            "-i", video_path, "-frames:v", "1", "-q:v", "2", frame_path
        ], timeout=15)

        if os.path.exists(frame_path) and os.path.exists(elem_path):
            with open(elem_path) as f:
                elements = json.load(f)

            annotated_path = os.path.join(annotated_dir,
                "annotated_{}.png".format(name))

            if draw_overlays(frame_path, elements, annotated_path):
                print("  Annotated {}: {} elements drawn".format(name, len(elements)))
                cap["annotated"] = "annotated/annotated_{}.png".format(name)
            else:
                print("  Overlay draw failed for {}".format(name))

# Generate narration for the best capture
print("\n" + "=" * 60)
print("Generating VoiceOver narration")
print("=" * 60)

narr_count = 0
for cap in best_captures[:3]:
    elem_path = cap["elements_path"]
    if os.path.exists(elem_path):
        with open(elem_path) as f:
            elements = json.load(f)
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
            narr_path = os.path.join(OUT_DIR, "narr_{}.aiff".format(cap["name"]))
            rc, _, _ = run_cmd(
                ["say", "-v", "Samantha", "-r", "180", "-o", narr_path, text], timeout=15)
            if rc == 0:
                narr_count += 1
                print("  Narration {}: {} bytes".format(
                    cap["name"], os.path.getsize(narr_path)))

# Save metadata
annotated_count = len([f for f in os.listdir(annotated_dir) if f.endswith(".png")])
metadata = {
    "total_captures": len(captures),
    "best_captures": best_captures,
    "test_duration_sec": round(test_duration, 1),
    "tests_passed": passed,
    "tests_failed": failed,
    "annotated_screenshots": annotated_count,
    "narration_segments": narr_count,
    "video_size": os.path.getsize(video_path) if os.path.exists(video_path) else 0,
}

with open(os.path.join(OUT_DIR, "timeline.json"), "w") as f:
    json.dump(metadata, f, indent=2)

# Per-capture element summary
for cap in captures[:5]:
    if os.path.exists(cap["elements_path"]):
        with open(cap["elements_path"]) as f:
            elems = json.load(f)
        print("\n  {} ({} elements):".format(cap["name"], len(elems)))
        for i, e in enumerate(elems[:6]):
            fr = e["frame"]
            print("    {:2d}. [{}] {} = {} ({},{} {}x{})".format(
                i + 1, e["role"][:8], e["label"][:25],
                (e["value"] or "")[:15],
                int(fr.get("x", 0)), int(fr.get("y", 0)),
                int(fr.get("width", fr.get("w", 0))),
                int(fr.get("height", fr.get("h", 0)))))

print("\n" + "=" * 60)
print("Pipeline complete")
print("  Total a11y captures: {}".format(len(captures)))
print("  Best captures: {}".format(len(best_captures)))
print("  Annotated screenshots: {}".format(annotated_count))
print("  Narrations: {}".format(narr_count))
print("  Video: {} bytes".format(os.path.getsize(video_path) if os.path.exists(video_path) else 0))
print("=" * 60)
sys.exit(0)
