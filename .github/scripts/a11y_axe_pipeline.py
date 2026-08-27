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


def run_test_streaming(cmd, log_path, timeout):
    """Run the xcuitest suite, streaming stdout+stderr straight to log_path.

    capture_output buffers in memory and TimeoutExpired throws it all away, so a
    timeout used to yield an empty log and no explanation for the missing scenario
    dumps. Streaming means a killed run still leaves everything it managed to emit.
    Returns (returncode, timed_out).
    """
    with open(log_path, "w") as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, text=True)
        try:
            return proc.wait(timeout=timeout), False
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            log.write("\n--- KILLED: exceeded {}s timeout ---\n".format(timeout))
            log.flush()
            return -1, True

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
rc, timed_out = run_test_streaming([
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
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ChoiceSetPlaceholderContrast_5536079",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ColumnSetChoiceSet_name",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_InputStyle_fieldName",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_CompoundButton_role",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_RtlFalse_phantomButton",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ActivityUpdate_dismissFocus",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_ActionMode_cancelFocus",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_RatingInput_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_FluentIconRTL_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_TooltipTestCard_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_CompoundButton_keyboard",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_Interactive_keyboard",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_InputLabel_link_swipe",
    "-only-testing:ADCIOSVisualizerUITests/ADCIOSVisualizerUITests/testA11yMAS_InlineAction_buttonName",
    "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO",
], os.path.join(OUT_DIR, "xcuitest.log"), timeout=3000)
test_dur = time.time() - start_time
print("[TEST] Completed in {:.1f}s (exit: {}, timed_out: {})".format(test_dur, rc, timed_out))

# The log is already on disk, streamed. Read it back so the parsing below is unchanged.
with open(os.path.join(OUT_DIR, "xcuitest.log"), errors="replace") as f:
    stdout = f.read()

if timed_out:
    print("!" * 60)
    print("[TEST] TIMED OUT after {:.0f}s - the suite was killed mid-run.".format(test_dur))
    print("[TEST] Scenarios after the kill point captured NOTHING. Absence of a")
    print("[TEST] scenario dump in this run means UNKNOWN, never 'no elements'.")
    print("[TEST] Do not cite this run as before/after evidence.")
    print("!" * 60)

# Parse results
for line in stdout.split("\n"):
    if "Test Case" in line and ("passed" in line or "failed" in line):
        print("  " + line.strip())
    if "A11Y_" in line:
        print("  " + line.strip().split("] ", 1)[-1] if "] " in line else line.strip())

# Record whether this run is trustworthy as evidence. A partial run must never be
# indistinguishable from a complete one in the artifacts.
n_dumps = len([f for f in os.listdir(XCUI_DIR) if f.endswith("_elements.json")]) \
    if os.path.isdir(XCUI_DIR) else 0
# ---------------------------------------------------------------------------
# Contrast
#
# Parsed from the A11Y_COLOR lines the in-app inspector emits under -a11yColorDump.
# Every foreground the inspector could see is scored, each tagged with the property it
# came from, because the failure this exists to prevent was reading one property and
# missing another: a placeholder measured through textColor reported 14:1 for glyphs that
# are actually about 1.67:1.
# ---------------------------------------------------------------------------
def _srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _relative_luminance(hex_color):
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return (0.2126 * _srgb_to_linear(r)
            + 0.7152 * _srgb_to_linear(g)
            + 0.0722 * _srgb_to_linear(b))


def _contrast_ratio(fg_hex, bg_hex):
    l1, l2 = _relative_luminance(fg_hex), _relative_luminance(bg_hex)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def build_contrast_report(log_text, out_dir):
    """Score every foreground sample against its background and write contrast_report.json."""
    records = []
    for line in log_text.split("\n"):
        marker = "A11Y_COLOR: "
        if marker not in line:
            continue
        try:
            records.append(json.loads(line.split(marker, 1)[1].strip()))
        except Exception:
            continue

    findings = []
    for rec in records:
        colors = rec.get("colors") or {}
        background = (colors.get("background") or {}).get("hex")
        for sample in colors.get("foregrounds") or []:
            fg = sample.get("hex")
            if not fg or not background:
                continue
            ratio = _contrast_ratio(fg, background)
            findings.append({
                "label": rec.get("label", ""),
                "viewClass": colors.get("viewClass", ""),
                "source": sample.get("source", ""),
                "foreground": fg,
                "background": background,
                "ratio": round(ratio, 3),
                # 4.5:1 is the WCAG AA threshold for normal-size text.
                "passesAA": ratio >= 4.5,
            })

    findings.sort(key=lambda f: f["ratio"])
    report = {
        "elements_with_color": len(records),
        "samples_scored": len(findings),
        "below_AA": [f for f in findings if not f["passesAA"]],
        "all": findings,
    }
    path = os.path.join(out_dir, "contrast_report.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=2)
    print("[CONTRAST] scored {} samples across {} elements; {} below 4.5:1".format(
        len(findings), len(records), len(report["below_AA"])))
    for f in report["below_AA"][:10]:
        print("[CONTRAST]   {:.3f}:1  {}  ({} on {})  {!r}".format(
            f["ratio"], f["source"], f["foreground"], f["background"], f["label"][:40]))
    return report


# rc 65 is xcodebuild's "a test assertion failed". That is the NORMAL outcome here: the
# scenarios assert on the buggy behaviour, so a run that correctly reproduces a bug exits
# 65 while producing perfectly good evidence. Gating on rc == 0 made this flag read False
# on every run including clean controls, which is worse than not having the flag at all.
# Only a timeout, a harness/infrastructure failure, or an empty capture invalidates dumps.
evidence_usable = (not timed_out) and rc in (0, 65) and n_dumps > 0

with open(os.path.join(OUT_DIR, "run_status.json"), "w") as f:
    json.dump({
        "timed_out": bool(timed_out),
        "returncode": rc,
        "test_duration_sec": round(test_dur, 1),
        "scenario_dumps_captured": n_dumps,
        "evidence_usable": evidence_usable,
    }, f, indent=2)
print("[STATUS] evidence_usable={} dumps={} rc={}".format(evidence_usable, n_dumps, rc))

# Score the colours the in-app inspector logged under -a11yColorDump. Runs regardless of
# rc for the same reason evidence_usable does: a scenario that reproduces a defect exits
# non-zero while still producing perfectly good measurements.
try:
    build_contrast_report(stdout, OUT_DIR)
except Exception as exc:
    print("[CONTRAST] report failed: {}".format(exc))

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
