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
    "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGNING_ALLOWED=NO",
], timeout=300)
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

# 5.5 Draw overlays with Pillow
print("\n[OVERLAY] Drawing accessibility overlays")
try:
    from PIL import Image, ImageDraw, ImageFont
    COLORS = [(0,122,255), (52,199,89), (255,149,0), (255,59,48),
              (175,82,222), (88,86,214), (255,45,85), (0,199,190)]
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
        img = Image.open(shot)
        draw = ImageDraw.Draw(img, "RGBA")
        sc = img.width / 393.0
        for i, e in enumerate(elems[:25]):
            fr = e.get("frame", {})
            x, y = int(fr.get("x",0)*sc), int(fr.get("y",0)*sc)
            w, h = int(fr.get("width",50)*sc), int(fr.get("height",30)*sc)
            if w < 5 or h < 5: continue
            c = COLORS[i % len(COLORS)]
            draw.rectangle([x,y,x+w,y+h], fill=c+(30,), outline=c+(200,), width=max(2,int(3*sc)))
            r = int(12*sc)
            draw.ellipse([x,y,x+r*2,y+r*2], fill=c+(255,))
            try:
                fnt = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(13*sc))
            except:
                fnt = ImageFont.load_default()
            draw.text((x+r//2, y+2), str(i+1), fill=(255,255,255), font=fnt)
            tag = "[{}] {}".format(e.get("role","")[:6], e.get("label","")[:25])
            try:
                sfnt = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", int(10*sc))
            except:
                sfnt = ImageFont.load_default()
            draw.text((x, y+h+2), tag, fill=(255,255,255), font=sfnt)
        out = os.path.join(OUT_DIR, "annotated_" + name + ".png")
        img.save(out)
        print("  ANNOTATED: {} ({} elements)".format(name, len(elems)))
except ImportError:
    print("  Pillow not available, skipping overlays")
except Exception as ex:
    print("  Overlay error: {}".format(ex))

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
