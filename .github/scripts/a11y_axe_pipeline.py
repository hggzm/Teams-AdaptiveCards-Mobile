import subprocess
#!/usr/bin/env python3
"""Simplified pipeline: XCUITest draws overlays natively via CoreGraphics.
This script just orchestrates: record video, run tests, collect outputs."""
import subprocess, json, os, sys, time, shutil

subprocess.run([sys.executable, "-m", "pip", "install", "-q", "Pillow"], capture_output=True)

UDID = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SIM_UDID", "")
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "/tmp/axe-output"
XCUI_DIR = "/tmp/a11y-xcui"
os.makedirs(OUT_DIR, exist_ok=True)

def run_cmd(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except Exception as e:
        return -1, "", str(e)

print("=" * 60)
print("iOS A11y Overlay Pipeline (CoreGraphics)")
print("UDID: {}".format(UDID))
print("=" * 60)

# 1. Start AXe video recording
video_path = os.path.join(OUT_DIR, "raw_recording.mp4")
has_axe = shutil.which("axe") is not None
if has_axe:
    rec_proc = subprocess.Popen(
        ["axe", "record-video", "--udid", UDID, "--fps", "15", "--output", video_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(2)
    print("[REC] Recording via AXe (PID: {})".format(rec_proc.pid))
else:
    # Fallback to simctl
    rec_proc = subprocess.Popen(
        ["xcrun", "simctl", "io", UDID, "recordVideo", "--codec", "h264", "--force", video_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(2)
    print("[REC] Recording via simctl (PID: {})".format(rec_proc.pid))

# 2. Clean and prepare
shutil.rmtree(XCUI_DIR, ignore_errors=True)
os.makedirs(XCUI_DIR, exist_ok=True)

# 3. Run XCUITests (they draw overlays natively via CoreGraphics)
print("[TEST] Running A11yDump XCUITests...")
start_time = time.time()
rc, stdout, stderr = run_cmd([
    "xcodebuild", "test-without-building",
    "-workspace", "source/ios/AdaptiveCards/AdaptiveCards.xcworkspace",
    "-scheme", "ADCIOSVisualizer",
    "-sdk", "iphonesimulator",
    "-destination", "platform=iOS Simulator,id={}".format(UDID),
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yDumpActivityUpdateShowCard",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yAutomation_ActivityUpdate",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yAutomation_ExpenseReport",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yAutomation_InputForm",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_FoodOrderShowCard_dropdown",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ColumnSetChoiceSet_name",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_InputStyle_fieldName",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_CompoundButton_role",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_RtlFalse_phantomButton",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ActivityUpdate_dismissFocus",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ActionMode_cancelFocus",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_RatingInput_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_FluentIconRTL_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_TooltipTestCard_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_InputLabel_link_swipe",
    "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO",
], timeout=1500)
test_dur = time.time() - start_time
print("[TEST] Completed in {:.1f}s (exit: {})".format(test_dur, rc))

with open(os.path.join(OUT_DIR, "xcuitest.log"), "w") as f:
    f.write(stdout + "\n--- STDERR ---\n" + stderr)

# Parse results
for line in stdout.split("\n"):
    if "Test Case" in line and ("passed" in line or "failed" in line):
        print("  " + line.strip())
    if "A11Y_" in line:
        print("  " + line.strip().split("] ", 1)[-1] if "] " in line else line.strip())

# 4. Stop recording
time.sleep(2)
if has_axe:
    rec_proc.send_signal(2)  # SIGINT
else:
    rec_proc.send_signal(2)
try:
    rec_proc.wait(timeout=15)
except:
    rec_proc.kill()
time.sleep(2)

if os.path.exists(video_path):
    shutil.copy2(video_path, os.path.join(OUT_DIR, "voiceover_demo.mp4"))
    print("[REC] Video: {} bytes".format(os.path.getsize(video_path)))

# 5. Collect XCUITest outputs
print("\n[COLLECT] Reading from {}".format(XCUI_DIR))
annotated_count = 0
element_count = 0
for f in sorted(os.listdir(XCUI_DIR)):
    src = os.path.join(XCUI_DIR, f)
    dst = os.path.join(OUT_DIR, f)
    shutil.copy2(src, dst)
    sz = os.path.getsize(src)
    if "annotated" in f:
        annotated_count += 1
        print("  ANNOTATED: {} ({} bytes)".format(f, sz))
    elif f.endswith("_elements.json"):
        with open(src) as fh:
            elems = json.load(fh)
        element_count += len(elems)
        print("  ELEMENTS: {} ({} elements)".format(f, len(elems)))
    elif f.endswith(".png"):
        print("  SCREENSHOT: {} ({} bytes)".format(f, sz))

# 5.5 Draw overlays with Pillow (matching Android TalkBack style)
print("\n[OVERLAY] Drawing accessibility overlays")
try:
    from PIL import Image, ImageDraw, ImageFont

    # TalkBack-style green colors
    FOCUS_FILL = (0, 200, 0, 40)       # Semi-transparent green fill
    FOCUS_BORDER = (0, 220, 0, 220)    # Green border
    BADGE_BG = (0, 150, 0, 240)        # Dark green badge
    TEXT_BG = (0, 0, 0, 180)           # Dark background for text readability

    for f in sorted(os.listdir(OUT_DIR)):
        if not f.endswith("_elements.json"):
            continue
        name = f.replace("_elements.json", "")
        shot = os.path.join(OUT_DIR, name + ".png")
        if not os.path.exists(shot):
            continue
        with open(os.path.join(OUT_DIR, f)) as fh:
            elems = json.load(fh)
        if not elems:
            continue

        img = Image.open(shot).convert("RGBA")
        overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)
        sc = img.width / 393.0  # @3x retina scale
        img_h = img.height

        # Filter: skip elements that overlap heavily (off-screen table cells)
        # and elements outside visible area
        seen_rects = set()
        visible_elems = []
        for e in elems:
            fr = e.get("frame", {})
            x = int(fr.get("x", 0) * sc)
            y = int(fr.get("y", 0) * sc)
            w = int(fr.get("width", 0) * sc)
            h = int(fr.get("height", 0) * sc)
            if w < 10 or h < 10: continue
            if y + h < 0 or y > img_h: continue  # Off screen
            if w > img.width * 0.95: continue      # Full-width containers
            rect_key = (x // 20, y // 20, w // 20, h // 20)
            if rect_key in seen_rects: continue    # Dedupe overlapping
            seen_rects.add(rect_key)
            visible_elems.append((e, x, y, w, h))

        try:
            font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(14 * sc))
            small_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(10 * sc))
        except:
            font = ImageFont.load_default()
            small_font = font

        for i, (e, x, y, w, h) in enumerate(visible_elems[:25]):
            # Green semi-transparent fill (like TalkBack focus rectangle)
            draw.rectangle([x, y, x + w, y + h], fill=FOCUS_FILL, outline=FOCUS_BORDER, width=max(2, int(2 * sc)))

            # Number badge (top-left, above the box)
            badge_sz = int(18 * sc)
            badge_y = max(0, y - badge_sz - 2)
            draw.ellipse([x, badge_y, x + badge_sz, badge_y + badge_sz], fill=BADGE_BG)
            num = str(i + 1)
            # Center number in badge
            try:
                bbox = font.getbbox(num)
                nw = bbox[2] - bbox[0]
                nh = bbox[3] - bbox[1]
            except:
                nw, nh = 10, 10
            draw.text((x + (badge_sz - nw) // 2, badge_y + (badge_sz - nh) // 2 - 2),
                      num, fill=(255, 255, 255, 255), font=font)

            # Label with dark background for readability
            label = e.get("label", "")[:35]
            role = e.get("role", "")
            tag = "[{}] {}".format(role, label)
            try:
                tbbox = small_font.getbbox(tag)
                tw = tbbox[2] - tbbox[0]
                th = tbbox[3] - tbbox[1]
            except:
                tw, th = len(tag) * 6, 12
            text_y = min(y + h + 2, img_h - th - 4)
            # Dark background pill
            draw.rectangle([x, text_y, x + tw + 8, text_y + th + 4], fill=TEXT_BG)
            draw.text((x + 4, text_y + 1), tag, fill=(255, 255, 255, 255), font=small_font)

        # Composite overlay onto original
        result = Image.alpha_composite(img, overlay)
        out = os.path.join(OUT_DIR, "annotated_" + name + ".png")
        result.convert("RGB").save(out)
        print("  ANNOTATED: {} ({} visible / {} total elements)".format(
            name, len(visible_elems), len(elems)))

except ImportError:
    print("  Pillow not available, skipping overlays")
except Exception as ex:
    import traceback
    print("  Overlay error: {}".format(ex))
    traceback.print_exc()

# 5.6 Generate a11y_transcript.json (matching Android format)
print("\n[TRANSCRIPT] Generating accessibility transcript")
all_transcripts = []
for f in sorted(os.listdir(OUT_DIR)):
    if not f.endswith("_elements.json"):
        continue
    name = f.replace("_elements.json", "")
    with open(os.path.join(OUT_DIR, f)) as fh:
        elems = json.load(fh)
    transcript_entry = {
        "scenario": name,
        "platform": "ios",
        "source": "XCUIElement (UIAccessibility API)",
        "nodes": [
            {
                "index": i + 1,
                "label": e.get("label", ""),
                "value": e.get("value", ""),
                "role": e.get("role", ""),
                "bounds": [
                    int(e["frame"].get("x", 0)),
                    int(e["frame"].get("y", 0)),
                    int(e["frame"].get("x", 0)) + int(e["frame"].get("width", 0)),
                    int(e["frame"].get("y", 0)) + int(e["frame"].get("height", 0)),
                ],
                "voiceover_reads": "{}{}.  {}".format(
                    e.get("label", ""),
                    (", " + e["value"]) if e.get("value") else "",
                    e.get("role", "")
                ),
            }
            for i, e in enumerate(elems)
        ]
    }
    all_transcripts.append(transcript_entry)
    print("  {}: {} elements".format(name, len(elems)))

transcript_path = os.path.join(OUT_DIR, "a11y_transcript.json")
with open(transcript_path, "w") as f:
    json.dump(all_transcripts, f, indent=2)
print("[TRANSCRIPT] Saved: {} scenarios, {} total nodes".format(
    len(all_transcripts), sum(len(t["nodes"]) for t in all_transcripts)))

# 5.7 Count annotated files  
annotated_files = [f for f in os.listdir(OUT_DIR) if f.startswith("annotated_") and f.endswith(".png")]
annotated_count = len(annotated_files)
print("[OVERLAY] {} annotated screenshots produced".format(annotated_count))

# 6. Generate narration from elements
print("\n[NARRATE] Generating VoiceOver speech")
narr_count = 0
for f in sorted(os.listdir(OUT_DIR)):
    if f.endswith("_elements.json"):
        with open(os.path.join(OUT_DIR, f)) as fh:
            elems = json.load(fh)
        name = f.replace("_elements.json", "")
        lines = []
        for e in elems[:10]:
            speech = e.get("label", "")
            if not speech: continue
            val = e.get("value", "")
            role = e.get("role", "")
            if val: speech += ", " + val
            speech += ". " + role + "."
            lines.append(speech)
        if lines:
            text = " ".join(lines)
            narr_path = os.path.join(OUT_DIR, "narr_{}.aiff".format(name))
            rc2, _, _ = run_cmd(["say", "-v", "Samantha", "-r", "180", "-o", narr_path, text])
            if rc2 == 0:
                narr_count += 1

# 7. Save metadata
metadata = {
    "test_duration_sec": round(test_dur, 1),
    "annotated_screenshots": annotated_count,
    "total_elements": element_count,
    "narrations": narr_count,
    "video_bytes": os.path.getsize(video_path) if os.path.exists(video_path) else 0,
}
with open(os.path.join(OUT_DIR, "timeline.json"), "w") as f:
    json.dump(metadata, f, indent=2)

print("\n" + "=" * 60)
print("Done")
print("  Annotated screenshots: {}".format(annotated_count))
print("  Total a11y elements: {}".format(element_count))
print("  Narrations: {}".format(narr_count))
print("  Video: {} bytes".format(metadata["video_bytes"]))
print("=" * 60)
sys.exit(0)
