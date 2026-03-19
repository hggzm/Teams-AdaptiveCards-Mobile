#!/usr/bin/env python3
"""
AXe-driven accessibility overlay pipeline.

Drives the ADCIOSVisualizer app using AXe CLI:
1. Launch app via xcrun simctl
2. Navigate to cards using AXe tap --label
3. At each step: capture describe-ui JSON + screenshot
4. Record video throughout
5. Post-process: draw a11y bounding boxes onto screenshots and video

Usage:
  python3 a11y_axe_pipeline.py <sim_udid> <app_bundle_id> <output_dir>
"""
import subprocess, json, os, sys, time, shutil
from pathlib import Path

UDID = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SIM_UDID", "")
APP_BUNDLE = sys.argv[2] if len(sys.argv) > 2 else "com.test.ADCIOSVisualizer"
OUT_DIR = sys.argv[3] if len(sys.argv) > 3 else "/tmp/axe-pipeline"
os.makedirs(OUT_DIR, exist_ok=True)

# Interaction script: each step is (action, label/args, description)
SCENARIO = [
    # Navigate to ActivityUpdate card
    ("launch", APP_BUNDLE, "Launch ADCIOSVisualizer"),
    ("wait", "3", "Wait for app to load"),
    ("describe", "01_app_launched", "App launched - initial state"),
    ("tap_label", "v1.5", "Navigate to v1.5 cards"),
    ("wait", "1", "Wait for navigation"),
    ("tap_label", "Scenarios", "Navigate to Scenarios"),
    ("wait", "1", "Wait for list"),
    ("describe", "02_scenarios_list", "Scenarios list visible"),
    ("tap_label", "ActivityUpdate.json", "Open ActivityUpdate card"),
    ("wait", "2", "Wait for card to render"),
    ("describe", "03_activity_card_rendered", "ActivityUpdate card rendered"),
    ("screenshot", "03_activity_card", "Screenshot of rendered card"),
    # ShowCard interaction - Comment button
    ("tap_label", "Comment", "Tap Comment ShowCard button"),
    ("wait", "1.5", "Wait for ShowCard to expand"),
    ("describe", "04_showcard_expanded", "ShowCard expanded - Comment form visible"),
    ("screenshot", "04_showcard_expanded", "ShowCard expanded state"),
    # Go back and try Set due date
    ("tap_label", "OK", "Tap OK to dismiss"),
    ("wait", "1", "Wait"),
    ("tap_label", "Set due date", "Tap Set due date ShowCard"),
    ("wait", "1.5", "Wait for date ShowCard"),
    ("describe", "05_date_showcard", "Date ShowCard expanded"),
    ("screenshot", "05_date_showcard", "Date ShowCard state"),
    # Navigate back
    ("tap_label", "Back", "Go back to card list"),
    ("wait", "1", "Wait"),
    ("tap_label", "Back", "Go back to version list"),
    ("wait", "1", "Wait"),
    # Try ExpenseReport
    ("tap_label", "v1.5", "Navigate to v1.5"),
    ("wait", "1", "Wait"),
    ("tap_label", "Scenarios", "Navigate to Scenarios"),
    ("wait", "1", "Wait"),
    ("tap_label", "ExpenseReport.json", "Open ExpenseReport card"),
    ("wait", "2", "Wait for card"),
    ("describe", "06_expense_card", "ExpenseReport card rendered"),
    ("screenshot", "06_expense_card", "ExpenseReport card"),
    # Final state
    ("describe", "07_final", "Final accessibility state"),
]


def run_cmd(cmd, timeout=30):
    """Run a command and return (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except Exception as e:
        return -1, "", str(e)


def axe_describe(udid, name):
    """Capture accessibility tree via AXe describe-ui."""
    out_path = os.path.join(OUT_DIR, "{}_a11y.json".format(name))
    rc, stdout, stderr = run_cmd(["axe", "describe-ui", "--udid", udid])
    if rc == 0 and stdout.strip():
        with open(out_path, "w") as f:
            f.write(stdout)
        # Parse and print summary
        try:
            tree = json.loads(stdout)
            elements = []
            def walk(node, depth=0):
                label = node.get("AXLabel", "")
                value = node.get("AXValue", "")
                role = node.get("role_description", "")
                frame = node.get("frame", {})
                if label and role:
                    elements.append({
                        "label": label, "value": value, "role": role,
                        "frame": frame, "depth": depth
                    })
                for child in node.get("children", []):
                    walk(child, depth + 1)
            for node in (tree if isinstance(tree, list) else [tree]):
                walk(node)
            # Save parsed elements
            parsed_path = os.path.join(OUT_DIR, "{}_elements.json".format(name))
            with open(parsed_path, "w") as f:
                json.dump(elements, f, indent=2)
            print("    describe-ui: {} elements".format(len(elements)))
            for e in elements[:8]:
                print("      [{}] {} = {}".format(e["role"], e["label"], e["value"] or ""))
            if len(elements) > 8:
                print("      ... and {} more".format(len(elements) - 8))
        except json.JSONDecodeError:
            print("    describe-ui: got output but not valid JSON")
    else:
        print("    describe-ui failed: {}".format(stderr[:100]))
        with open(out_path, "w") as f:
            f.write(stderr)


def axe_screenshot(udid, name):
    """Capture screenshot via AXe."""
    out_path = os.path.join(OUT_DIR, "{}.png".format(name))
    rc, stdout, stderr = run_cmd(
        ["axe", "screenshot", "--output", out_path, "--udid", udid])
    if rc == 0 and os.path.exists(out_path):
        sz = os.path.getsize(out_path)
        print("    screenshot: {} bytes".format(sz))
    else:
        print("    screenshot failed: {}".format(stderr[:100]))


def axe_tap(udid, label):
    """Tap element by accessibility label."""
    rc, stdout, stderr = run_cmd(
        ["axe", "tap", "--label", label, "--udid", udid])
    if rc == 0:
        print("    tap '{}': OK".format(label))
    else:
        print("    tap '{}': FAILED ({})".format(label, stderr.strip()[:80]))
    return rc == 0


def draw_a11y_overlays(screenshot_path, elements_path, output_path):
    """Draw accessibility bounding boxes onto a screenshot using ffmpeg drawbox."""
    if not os.path.exists(screenshot_path) or not os.path.exists(elements_path):
        return False

    with open(elements_path) as f:
        elements = json.load(f)

    if not elements:
        shutil.copy2(screenshot_path, output_path)
        return True

    # Build ffmpeg drawbox + drawtext filter chain
    filters = []
    colors = ["#007AFF", "#34C759", "#FF9500", "#FF3B30", "#AF52DE",
              "#5856D6", "#FF2D55", "#00C7BE"]

    for i, elem in enumerate(elements[:15]):  # Limit to 15 elements
        frame = elem.get("frame", {})
        x = int(frame.get("x", 0))
        y = int(frame.get("y", 0))
        w = int(frame.get("w", frame.get("width", 50)))
        h = int(frame.get("h", frame.get("height", 30)))
        color = colors[i % len(colors)]
        label = elem.get("label", "")
        role = elem.get("role", "")

        # Draw bounding box
        filters.append(
            "drawbox=x={}:y={}:w={}:h={}:color={}@0.6:t=3".format(x, y, w, h, color))

        # Draw label text above the box
        safe_label = label.replace("'", "").replace(":", " ").replace(",", " ")[:30]
        tag = "[{}] {}".format(role[:6], safe_label)
        safe_tag = tag.replace("'", "").replace(":", " ")
        filters.append(
            "drawtext=text='{}':fontsize=14:fontcolor=white"
            ":borderw=1:bordercolor=black"
            ":x={}:y={}".format(safe_tag, x, max(0, y - 18)))

        # Draw index number inside the box
        filters.append(
            "drawtext=text='{}':fontsize=18:fontcolor=white"
            ":borderw=2:bordercolor={}:x={}:y={}".format(
                i + 1, color, x + 4, y + 2))

    if not filters:
        shutil.copy2(screenshot_path, output_path)
        return True

    filter_str = ",".join(filters)
    rc, _, stderr = run_cmd([
        "ffmpeg", "-y", "-i", screenshot_path,
        "-vf", filter_str,
        output_path
    ], timeout=30)

    return rc == 0


def generate_narration(elements_path, output_path, voice="Samantha"):
    """Generate VoiceOver-style narration from elements using macOS say."""
    if not os.path.exists(elements_path):
        return False

    with open(elements_path) as f:
        elements = json.load(f)

    # Build narration text
    lines = []
    for elem in elements[:10]:
        label = elem.get("label", "")
        value = elem.get("value", "")
        role = elem.get("role", "")
        if not label:
            continue
        speech = label
        if value:
            speech += ", " + value
        speech += ". " + role + "."
        lines.append(speech)

    if not lines:
        return False

    narration_text = " ".join(lines)
    rc, _, _ = run_cmd(
        ["say", "-v", voice, "-r", "180", "-o", output_path, narration_text])
    return rc == 0


# ═══════════════════════════════════════════════════════════════
# Main pipeline
# ═══════════════════════════════════════════════════════════════

print("=" * 60)
print("AXe Accessibility Overlay Pipeline")
print("UDID: {}".format(UDID))
print("App:  {}".format(APP_BUNDLE))
print("Out:  {}".format(OUT_DIR))
print("=" * 60)

# Start video recording
print("\n[REC] Starting AXe video recording...")
video_path = os.path.join(OUT_DIR, "raw_recording.mp4")
rec_proc = subprocess.Popen(
    ["axe", "record-video", "--udid", UDID, "--fps", "15", "--output", video_path],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
time.sleep(2)
print("[REC] Recording PID: {}".format(rec_proc.pid))

# Run interaction scenario
timeline = []  # [{timestamp, step, description, elements_file}]
start_time = time.time()

for step_idx, (action, arg, desc) in enumerate(SCENARIO):
    elapsed = time.time() - start_time
    print("\n[{:5.1f}s] Step {}: {} ({} {})".format(elapsed, step_idx + 1, desc, action, arg))

    entry = {"timestamp": round(elapsed, 1), "step": step_idx + 1,
             "action": action, "arg": arg, "description": desc}

    if action == "launch":
        rc, _, stderr = run_cmd(["xcrun", "simctl", "launch", UDID, arg])
        if rc == 0:
            print("    Launched: {}".format(arg))
        else:
            print("    Launch failed: {}".format(stderr[:100]))
    elif action == "wait":
        time.sleep(float(arg))
    elif action == "describe":
        axe_describe(UDID, arg)
        entry["elements_file"] = "{}_elements.json".format(arg)
    elif action == "screenshot":
        axe_screenshot(UDID, arg)
        entry["screenshot_file"] = "{}.png".format(arg)
    elif action == "tap_label":
        success = axe_tap(UDID, arg)
        entry["success"] = success

    timeline.append(entry)

# Stop recording
print("\n[REC] Stopping recording...")
rec_proc.send_signal(2)  # SIGINT
try:
    rec_proc.wait(timeout=15)
except:
    rec_proc.kill()
time.sleep(2)

if os.path.exists(video_path):
    print("[REC] Recording: {} bytes".format(os.path.getsize(video_path)))
else:
    print("[REC] WARNING: No recording file")

# Save timeline
timeline_path = os.path.join(OUT_DIR, "timeline.json")
with open(timeline_path, "w") as f:
    json.dump(timeline, f, indent=2)

# ═══════════════════════════════════════════════════════════════
# Post-processing: draw overlays onto screenshots
# ═══════════════════════════════════════════════════════════════
print("\n" + "=" * 60)
print("Post-processing: drawing accessibility overlays")
print("=" * 60)

annotated_dir = os.path.join(OUT_DIR, "annotated")
os.makedirs(annotated_dir, exist_ok=True)

for entry in timeline:
    elements_file = entry.get("elements_file")
    screenshot_file = entry.get("screenshot_file")

    if elements_file and screenshot_file:
        # Both exist for this step - draw overlays
        elements_path = os.path.join(OUT_DIR, elements_file)
        screenshot_path = os.path.join(OUT_DIR, screenshot_file)
        annotated_path = os.path.join(annotated_dir,
            "annotated_" + screenshot_file)

        if draw_a11y_overlays(screenshot_path, elements_path, annotated_path):
            print("  Annotated: {}".format(annotated_path))
            entry["annotated_file"] = "annotated/" + "annotated_" + screenshot_file
    elif elements_file:
        # Only elements - find nearest screenshot
        elements_path = os.path.join(OUT_DIR, elements_file)
        # Take a fresh screenshot for this describe step
        shot_name = elements_file.replace("_elements.json", "")
        shot_path = os.path.join(OUT_DIR, shot_name + ".png")
        if os.path.exists(shot_path):
            annotated_path = os.path.join(annotated_dir,
                "annotated_" + shot_name + ".png")
            if draw_a11y_overlays(shot_path, elements_path, annotated_path):
                print("  Annotated: {}".format(annotated_path))
                entry["annotated_file"] = "annotated/annotated_" + shot_name + ".png"

# Generate narration for key moments
print("\n" + "=" * 60)
print("Generating VoiceOver narration")
print("=" * 60)

narration_segments = []
for entry in timeline:
    elements_file = entry.get("elements_file")
    if elements_file:
        elements_path = os.path.join(OUT_DIR, elements_file)
        narr_name = elements_file.replace("_elements.json", "")
        narr_path = os.path.join(OUT_DIR, "narr_{}.aiff".format(narr_name))
        if generate_narration(elements_path, narr_path):
            print("  Narration: {} ({} bytes)".format(
                narr_name, os.path.getsize(narr_path)))
            narration_segments.append({
                "file": narr_path,
                "timestamp": entry["timestamp"],
                "name": narr_name
            })

# Save final timeline
with open(timeline_path, "w") as f:
    json.dump({"timeline": timeline, "narration_segments": narration_segments}, f, indent=2)

# Copy raw recording as final if post-processing not needed
final_video = os.path.join(OUT_DIR, "voiceover_demo.mp4")
if os.path.exists(video_path):
    shutil.copy2(video_path, final_video)

print("\n" + "=" * 60)
print("Pipeline complete")
print("  Video: {}".format(final_video if os.path.exists(final_video) else "NONE"))
print("  Timeline: {}".format(timeline_path))
print("  Annotated screenshots: {}".format(
    len([e for e in timeline if e.get("annotated_file")])))
print("  Narration segments: {}".format(len(narration_segments)))
print("=" * 60)
