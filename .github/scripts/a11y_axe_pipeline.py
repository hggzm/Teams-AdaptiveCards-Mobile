#!/usr/bin/env python3
"""
AXe-driven accessibility overlay pipeline with point-grid scanning.

Drives the ADCIOSVisualizer app using AXe CLI, then scans a grid of
screen coordinates with `axe describe-ui --point X,Y` to discover
every accessibility element and its exact bounding box. Draws numbered
overlays onto screenshots (RocketSim-style).

Usage:
  python3 a11y_axe_pipeline.py <sim_udid> <app_bundle_id> <output_dir>
"""
import subprocess, json, os, sys, time, shutil, hashlib
from pathlib import Path

UDID = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SIM_UDID", "")
APP_BUNDLE = sys.argv[2] if len(sys.argv) > 2 else "com.test.ADCIOSVisualizer"
OUT_DIR = sys.argv[3] if len(sys.argv) > 3 else "/tmp/axe-pipeline"
os.makedirs(OUT_DIR, exist_ok=True)

# Simulator screen dimensions (iPhone 15 Pro logical)
SCREEN_W = 393
SCREEN_H = 852
# Grid step for point scanning (smaller = more elements found, slower)
GRID_STEP = 30
# Card content area (exclude status bar and nav bar)
SCAN_Y_START = 100
SCAN_Y_END = 800

def run_cmd(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except Exception as e:
        return -1, "", str(e)


def axe_describe_point(udid, x, y):
    """Get accessibility element at a specific screen point."""
    rc, stdout, stderr = run_cmd(
        ["axe", "describe-ui", "--point", "{},{}".format(x, y), "--udid", udid], timeout=5)
    if rc == 0 and stdout.strip():
        try:
            data = json.loads(stdout)
            # describe-ui --point returns a single element or array
            if isinstance(data, list) and len(data) > 0:
                return data[0]
            elif isinstance(data, dict):
                return data
        except json.JSONDecodeError:
            pass
    return None


def scan_grid(udid, name, step=GRID_STEP):
    """Scan a grid of points to discover all accessibility elements."""
    print("    Scanning {}x{} grid (step={})...".format(
        (SCREEN_W // step), ((SCAN_Y_END - SCAN_Y_START) // step), step))

    elements = {}  # keyed by unique_id or label+frame hash
    scan_count = 0

    for y in range(SCAN_Y_START, SCAN_Y_END, step):
        for x in range(20, SCREEN_W - 20, step):
            elem = axe_describe_point(udid, x, y)
            if elem:
                # Build unique key
                uid = elem.get("AXUniqueId") or ""
                label = elem.get("AXLabel") or ""
                frame = elem.get("frame", {})
                role = elem.get("role_description") or elem.get("role", "")

                # Skip empty/application-level elements
                if not label or role in ("application", "window", ""):
                    continue

                key = uid if uid else hashlib.md5(
                    "{}:{}:{}".format(label, role, json.dumps(frame, sort_keys=True)).encode()
                ).hexdigest()

                if key not in elements:
                    elements[key] = {
                        "label": label,
                        "value": elem.get("AXValue") or "",
                        "role": role,
                        "frame": frame,
                        "uid": uid,
                        "help": elem.get("help") or "",
                        "enabled": elem.get("enabled", True),
                    }
            scan_count += 1

    # Sort by position (top-left to bottom-right, reading order)
    sorted_elems = sorted(elements.values(),
        key=lambda e: (e["frame"].get("y", 0), e["frame"].get("x", 0)))

    # Save
    out_path = os.path.join(OUT_DIR, "{}_elements.json".format(name))
    with open(out_path, "w") as f:
        json.dump(sorted_elems, f, indent=2)

    print("    Found {} unique elements from {} points".format(len(sorted_elems), scan_count))
    for i, e in enumerate(sorted_elems[:12]):
        fr = e["frame"]
        print("      {:2d}. [{}] {} = {} ({},{} {}x{})".format(
            i + 1, e["role"][:8], e["label"][:25],
            (e["value"] or "")[:15],
            int(fr.get("x", 0)), int(fr.get("y", 0)),
            int(fr.get("width", 0)), int(fr.get("height", 0))))
    if len(sorted_elems) > 12:
        print("      ... and {} more".format(len(sorted_elems) - 12))

    return sorted_elems


def axe_screenshot(udid, name):
    """Capture screenshot via AXe."""
    out_path = os.path.join(OUT_DIR, "{}.png".format(name))
    rc, stdout, stderr = run_cmd(
        ["axe", "screenshot", "--output", out_path, "--udid", udid])
    if rc == 0 and os.path.exists(out_path):
        print("    screenshot: {} bytes".format(os.path.getsize(out_path)))
        return out_path
    else:
        print("    screenshot failed: {}".format(stderr[:80]))
        return None


def axe_tap(udid, label):
    """Tap element by accessibility label."""
    rc, stdout, stderr = run_cmd(
        ["axe", "tap", "--label", label, "--udid", udid], timeout=10)
    if rc == 0:
        print("    tap '{}': OK".format(label))
    else:
        print("    tap '{}': FAILED ({})".format(label, stderr.strip()[:60]))
    return rc == 0


def draw_overlays(screenshot_path, elements, output_path):
    """Draw numbered bounding boxes onto a screenshot using ffmpeg."""
    if not os.path.exists(screenshot_path) or not elements:
        return False

    # iOS screenshots are @2x or @3x, so we need to scale coordinates
    # AXe reports logical coordinates; screenshots are in pixels
    # Detect scale factor from image size
    rc, stdout, _ = run_cmd([
        "ffprobe", "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height",
        "-of", "csv=p=0", screenshot_path
    ])
    if rc == 0 and stdout.strip():
        parts = stdout.strip().split(",")
        img_w = int(parts[0])
        scale = img_w / SCREEN_W  # e.g. 786/393 = 2.0 for @2x
    else:
        scale = 2.0  # Default to @2x

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
        w = int(fr.get("width", 50) * scale)
        h = int(fr.get("height", 30) * scale)
        color = colors[i % len(colors)]
        label = elem.get("label", "")
        role = elem.get("role", "")[:6]

        # Bounding box
        filters.append(
            "drawbox=x={}:y={}:w={}:h={}:color={}@0.5:t=4".format(x, y, w, h, color))

        # Index number circle (top-left of box)
        num = str(i + 1)
        filters.append(
            "drawtext=text='{}':fontsize={}:fontcolor=white"
            ":borderw=3:bordercolor={}:x={}:y={}".format(
                num, int(20 * scale), color, x + 4, y + 2))

        # Label text (below box)
        safe_label = label.replace("'", "").replace(":", " ").replace("\\", "")[:25]
        safe_tag = "[{}] {}".format(role, safe_label).replace("'", "").replace(":", " ")
        text_y = min(y + h + 2, int(SCREEN_H * scale) - int(16 * scale))
        filters.append(
            "drawtext=text='{}':fontsize={}:fontcolor=white"
            ":borderw=1:bordercolor=black:x={}:y={}".format(
                safe_tag, int(11 * scale), x, text_y))

    filter_str = ",".join(filters)
    rc, _, stderr = run_cmd([
        "ffmpeg", "-y", "-i", screenshot_path,
        "-vf", filter_str,
        output_path
    ], timeout=30)

    if rc == 0:
        print("    overlays: {} elements drawn".format(min(len(elements), 20)))
        return True
    else:
        print("    overlay draw failed: {}".format(stderr[:120]))
        return False


# Interaction steps: action, arg, description, scan_after
SCENARIO = [
    ("launch", APP_BUNDLE, "Launch app", False),
    ("wait", "3", "Wait for app", False),
    ("tap_label", "v1.5", "Tap v1.5", False),
    ("wait", "1", "Wait", False),
    ("tap_label", "Scenarios", "Tap Scenarios", False),
    ("wait", "1", "Wait for list", False),
    ("tap_label", "ActivityUpdate.json", "Open ActivityUpdate card", False),
    ("wait", "2", "Wait for card render", False),
    ("scan_and_screenshot", "01_activity_card", "ActivityUpdate card rendered", True),
    ("tap_label", "Comment", "Tap Comment ShowCard", False),
    ("wait", "1.5", "Wait for ShowCard expand", False),
    ("scan_and_screenshot", "02_showcard_comment", "ShowCard Comment expanded", True),
    ("tap_label", "OK", "Dismiss comment", False),
    ("wait", "1", "Wait", False),
    ("tap_label", "Set due date", "Tap Set due date", False),
    ("wait", "1.5", "Wait for date ShowCard", False),
    ("scan_and_screenshot", "03_showcard_date", "ShowCard date expanded", True),
    ("tap_label", "Back", "Back to list", False),
    ("wait", "1", "Wait", False),
    ("tap_label", "Back", "Back to versions", False),
    ("wait", "1", "Wait", False),
    ("tap_label", "v1.5", "Tap v1.5", False),
    ("wait", "1", "Wait", False),
    ("tap_label", "Scenarios", "Tap Scenarios", False),
    ("wait", "1", "Wait", False),
    ("tap_label", "ExpenseReport.json", "Open ExpenseReport", False),
    ("wait", "2", "Wait for card", False),
    ("scan_and_screenshot", "04_expense_card", "ExpenseReport card rendered", True),
]

print("=" * 60)
print("AXe Point-Grid Overlay Pipeline")
print("UDID: {}".format(UDID))
print("Grid: {}px step, scanning y={}-{}".format(GRID_STEP, SCAN_Y_START, SCAN_Y_END))
print("=" * 60)

# Start video recording
video_path = os.path.join(OUT_DIR, "raw_recording.mp4")
rec_proc = subprocess.Popen(
    ["axe", "record-video", "--udid", UDID, "--fps", "15", "--output", video_path],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
time.sleep(2)
print("[REC] Recording PID: {}".format(rec_proc.pid))

# Run scenario
timeline = []
annotated_dir = os.path.join(OUT_DIR, "annotated")
os.makedirs(annotated_dir, exist_ok=True)
start_time = time.time()

for action, arg, desc, do_scan in SCENARIO:
    elapsed = time.time() - start_time
    print("\n[{:5.1f}s] {} ({} {})".format(elapsed, desc, action, arg))

    entry = {"timestamp": round(elapsed, 1), "action": action,
             "arg": arg, "description": desc}

    if action == "launch":
        run_cmd(["xcrun", "simctl", "launch", UDID, arg])
    elif action == "wait":
        time.sleep(float(arg))
    elif action == "tap_label":
        entry["success"] = axe_tap(UDID, arg)
    elif action == "scan_and_screenshot":
        # Take screenshot first
        shot_path = axe_screenshot(UDID, arg)
        entry["screenshot"] = "{}.png".format(arg)

        # Scan grid for elements
        elements = scan_grid(UDID, arg, step=GRID_STEP)
        entry["element_count"] = len(elements)

        # Draw overlays
        if shot_path and elements:
            annotated_path = os.path.join(annotated_dir, "annotated_{}.png".format(arg))
            if draw_overlays(shot_path, elements, annotated_path):
                entry["annotated"] = "annotated/annotated_{}.png".format(arg)

    timeline.append(entry)

# Stop recording
print("\n[REC] Stopping recording...")
rec_proc.send_signal(2)
try:
    rec_proc.wait(timeout=15)
except:
    rec_proc.kill()
time.sleep(2)

if os.path.exists(video_path):
    print("[REC] Recording: {} bytes".format(os.path.getsize(video_path)))
    shutil.copy2(video_path, os.path.join(OUT_DIR, "voiceover_demo.mp4"))

# Save timeline
with open(os.path.join(OUT_DIR, "timeline.json"), "w") as f:
    json.dump({"timeline": timeline}, f, indent=2)

# Generate narration for scanned steps
print("\n" + "=" * 60)
print("Generating VoiceOver narration from scanned elements")
print("=" * 60)

for entry in timeline:
    if entry.get("element_count", 0) > 0:
        name = entry["arg"]
        elements_path = os.path.join(OUT_DIR, "{}_elements.json".format(name))
        if os.path.exists(elements_path):
            with open(elements_path) as f:
                elems = json.load(f)
            lines = []
            for e in elems[:8]:
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
                narr_path = os.path.join(OUT_DIR, "narr_{}.aiff".format(name))
                rc, _, _ = run_cmd(
                    ["say", "-v", "Samantha", "-r", "180", "-o", narr_path, text], timeout=15)
                if rc == 0:
                    print("  Narration {}: {} bytes".format(name, os.path.getsize(narr_path)))

# Summary
annotated_count = len([f for f in os.listdir(annotated_dir) if f.endswith(".png")])
scan_steps = [e for e in timeline if e.get("element_count", 0) > 0]

print("\n" + "=" * 60)
print("Pipeline complete")
print("  Video: {}".format(video_path if os.path.exists(video_path) else "NONE"))
print("  Scanned steps: {}".format(len(scan_steps)))
print("  Annotated screenshots: {}".format(annotated_count))
for s in scan_steps:
    print("    {} — {} elements, annotated={}".format(
        s["description"], s["element_count"], bool(s.get("annotated"))))
print("=" * 60)

# Exit 0 even if some taps failed (pipeline produced artifacts)
sys.exit(0)
