#!/usr/bin/env python3
"""Post-process the raw simulator recording:
1. Detect first meaningful frame (skip app launch/splash)
2. Trim to start at first interaction
3. Generate VoiceOver narration audio with macOS `say`
4. Burn accessibility text overlays onto the video
5. Merge narration audio track
"""
import subprocess, json, os, sys, shutil, re
from pathlib import Path

raw_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-recordings/raw_test_recording.mp4"
transcript_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/a11y-recordings/transcript.json"
xcuitest_log = sys.argv[3] if len(sys.argv) > 3 else "/tmp/a11y-recordings/xcuitest.log"
out_path = sys.argv[4] if len(sys.argv) > 4 else "/tmp/a11y-recordings/voiceover_demo.mp4"
work_dir = "/tmp/a11y-postprocess"
os.makedirs(work_dir, exist_ok=True)

def run(cmd, timeout=60):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r

def get_duration(path):
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path])
    try:
        return float(r.stdout.strip())
    except:
        return 0.0

# ─── Step 1: Detect first meaningful frame ───
print("=== Step 1: Detect first meaningful frame ===")
total_dur = get_duration(raw_path)
print("  Raw video duration: {:.1f}s".format(total_dur))

# Extract frames every 0.5s and find where content first appears
# by comparing consecutive frame sizes (app content >> splash screen)
trim_start = 0.0
frame_sizes = []
for t in range(0, min(int(total_dur * 2), 40)):  # Check first 20 seconds
    ts = t * 0.5
    frame_path = os.path.join(work_dir, "probe_{:03d}.png".format(t))
    run(["ffmpeg", "-y", "-ss", str(ts), "-i", raw_path,
         "-frames:v", "1", "-q:v", "2", frame_path], timeout=10)
    if os.path.exists(frame_path):
        sz = os.path.getsize(frame_path)
        frame_sizes.append((ts, sz))

if frame_sizes:
    # Find the first big frame size jump (indicates app loaded with card content)
    # Initial frames are ~small (home screen / splash), card content is ~large
    avg_initial = sum(s for _, s in frame_sizes[:4]) / min(4, len(frame_sizes))
    for ts, sz in frame_sizes:
        # When frame gets significantly larger or changes pattern, card is visible
        if sz > avg_initial * 1.3 and ts > 1.0:
            # Start 1 second before the detected change for context
            trim_start = max(0, ts - 1.0)
            print("  First content frame at {:.1f}s (size: {} vs avg: {:.0f})".format(
                ts, sz, avg_initial))
            break

    if trim_start == 0.0:
        # Fallback: look for the largest frame-to-frame size change
        max_delta = 0
        for i in range(1, len(frame_sizes)):
            delta = abs(frame_sizes[i][1] - frame_sizes[i-1][1])
            if delta > max_delta:
                max_delta = delta
                trim_start = max(0, frame_sizes[i][0] - 1.0)

print("  Trim start: {:.1f}s".format(trim_start))

# ─── Step 2: Parse XCUITest log for interaction timing ───
print("\n=== Step 2: Parse XCUITest interaction timing ===")
interactions = []
if os.path.exists(xcuitest_log):
    with open(xcuitest_log) as f:
        for line in f:
            m = re.search(r"Test Case.*?(\w+)\]' (started|passed|failed)(?: \((\d+\.\d+) seconds\))?", line)
            if m:
                test_name = m.group(1)
                action = m.group(2)
                duration = float(m.group(3)) if m.group(3) else 0
                if action == "started":
                    interactions.append({"test": test_name, "action": "started"})
                elif action in ("passed", "failed"):
                    if interactions and interactions[-1]["test"] == test_name:
                        interactions[-1]["action"] = action
                        interactions[-1]["duration"] = duration

# Map test names to readable scenarios
SCENARIO_MAP = {
    "testSmokeTestActivityUpdateComment": "ShowCard: Comment (PR #660)",
    "testSmokeTestActivityUpdateDate": "ShowCard: Set Due Date (PR #660)",
    "testFocusOnValidationFailure": "Validation Error Focus (PR #662)",
}

# Build timed overlay annotations
annotations = []
cumulative = 0.0
for inter in interactions:
    test = inter["test"]
    dur = inter.get("duration", 5.0)
    scenario = SCENARIO_MAP.get(test, test)
    result = inter.get("action", "unknown")

    # VoiceOver announcements for each scenario
    vo_announcements = []
    if "Comment" in scenario:
        vo_announcements = [
            (0.0, "Comment, collapsed. Button."),
            (1.5, "Comment, card expanded. Button."),
            (3.0, "Enter your comment. Text field."),
        ]
    elif "Date" in scenario:
        vo_announcements = [
            (0.0, "Set due date, collapsed. Button."),
            (1.5, "Set due date, card expanded. Button."),
        ]
    elif "Validation" in scenario:
        vo_announcements = [
            (0.0, "Submit. Button."),
            (1.5, "Validation error. Required field."),
        ]

    annotations.append({
        "start": cumulative,
        "duration": dur,
        "scenario": scenario,
        "result": result,
        "vo_announcements": vo_announcements,
    })
    cumulative += dur + 0.5

print("  {} interactions found".format(len(interactions)))
for a in annotations:
    print("    [{:.1f}s] {} ({:.1f}s)".format(a["start"], a["scenario"], a["duration"]))

# ─── Step 3: Trim video ───
print("\n=== Step 3: Trim video ===")
trimmed_path = os.path.join(work_dir, "trimmed.mp4")
if trim_start > 0.5:
    r = run(["ffmpeg", "-y", "-ss", str(trim_start), "-i", raw_path,
             "-c:v", "libx264", "-preset", "fast", "-crf", "23",
             "-an", trimmed_path], timeout=120)
    if r.returncode != 0:
        print("  Trim failed, using raw: " + r.stderr[:200])
        shutil.copy2(raw_path, trimmed_path)
else:
    shutil.copy2(raw_path, trimmed_path)
trimmed_dur = get_duration(trimmed_path)
print("  Trimmed duration: {:.1f}s (removed {:.1f}s of launch)".format(trimmed_dur, trim_start))

# ─── Step 4: Generate VoiceOver narration audio ───
print("\n=== Step 4: Generate VoiceOver narration ===")
segments_dir = os.path.join(work_dir, "audio")
os.makedirs(segments_dir, exist_ok=True)

narration_segments = []
for i, ann in enumerate(annotations):
    for j, (offset, text) in enumerate(ann.get("vo_announcements", [])):
        seg_file = os.path.join(segments_dir, "seg_{:02d}_{:02d}.aiff".format(i, j))
        r = run(["say", "-v", "Samantha", "-r", "190", "-o", seg_file, text], timeout=15)
        if r.returncode == 0 and os.path.exists(seg_file):
            # The absolute time in the trimmed video
            abs_time = ann["start"] + offset
            narration_segments.append({"file": seg_file, "time": abs_time, "text": text})
            print("    [{:.1f}s] {}".format(abs_time, text))

# Build narration audio track with segments placed at correct timestamps
narration_path = os.path.join(work_dir, "narration.m4a")
if narration_segments and shutil.which("ffmpeg"):
    # Create a silent audio track matching video duration
    filter_parts = []
    inputs = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono"]
    input_idx = 1

    for seg in narration_segments:
        inputs.extend(["-i", seg["file"]])
        # Delay each segment to its timestamp
        delay_ms = int(seg["time"] * 1000)
        filter_parts.append("[{}:a]aformat=sample_rates=44100:channel_layouts=mono,adelay={}|{}[s{}]".format(
            input_idx, delay_ms, delay_ms, input_idx))
        input_idx += 1

    # Mix all segments with the silent base
    if filter_parts:
        mix_inputs = "[0:a]" + "".join("[s{}]".format(i+1) for i in range(len(narration_segments)))
        filter_str = ";".join(filter_parts) + ";" + mix_inputs + "amix=inputs={}:duration=first[aout]".format(
            len(narration_segments) + 1)
        cmd = ["ffmpeg", "-y"] + inputs + [
            "-t", str(trimmed_dur),
            "-filter_complex", filter_str,
            "-map", "[aout]",
            "-c:a", "aac", "-b:a", "128k",
            "-t", str(trimmed_dur),
            narration_path
        ]
        r = run(cmd, timeout=120)
        if r.returncode == 0:
            print("  Narration audio: {} bytes".format(os.path.getsize(narration_path)))
        else:
            print("  Narration mix failed: " + r.stderr[:300])
            narration_path = None
    else:
        narration_path = None
else:
    narration_path = None

# ─── Step 5: Build ffmpeg drawtext overlay filter ───
print("\n=== Step 5: Build accessibility text overlays ===")
drawtext_parts = []

for ann in annotations:
    start = ann["start"]
    end = start + ann["duration"]
    scenario = ann["scenario"]
    result = ann["result"].upper()

    # Scenario banner at top
    escaped_scenario = scenario.replace(":", "\\:").replace("'", "\\'")
    drawtext_parts.append(
        "drawtext=text='{}':fontsize=28:fontcolor=white:borderw=2:bordercolor=black"
        ":x=20:y=20:enable='between(t,{:.1f},{:.1f})'".format(escaped_scenario, start, end)
    )
    # Result badge
    result_color = "green" if result == "PASSED" else "red"
    drawtext_parts.append(
        "drawtext=text='{}':fontsize=22:fontcolor={}:borderw=2:bordercolor=black"
        ":x=20:y=55:enable='between(t,{:.1f},{:.1f})'".format(result, result_color, start, end)
    )

    # VoiceOver announcement overlays at bottom
    for offset, text in ann.get("vo_announcements", []):
        abs_start = start + offset
        abs_end = abs_start + 1.8  # Show for 1.8 seconds
        escaped_text = text.replace(":", "\\:").replace("'", "\\'").replace(",", "\\,")
        # VoiceOver focus box at bottom
        drawtext_parts.append(
            "drawtext=text='VoiceOver\\: {}':fontsize=20:fontcolor=white"
            ":borderw=2:bordercolor=0x007AFF:box=1:boxcolor=0x007AFF@0.7:boxborderw=8"
            ":x=(w-text_w)/2:y=h-60:enable='between(t,{:.1f},{:.1f})'".format(
                escaped_text, abs_start, abs_end)
        )

overlay_filter = ",".join(drawtext_parts) if drawtext_parts else ""
print("  {} overlay segments".format(len(drawtext_parts)))

# ─── Step 6: Produce final video ───
print("\n=== Step 6: Produce final video ===")

if overlay_filter:
    cmd = ["ffmpeg", "-y", "-i", trimmed_path]
    if narration_path and os.path.exists(narration_path):
        cmd.extend(["-i", narration_path])
        cmd.extend([
            "-filter_complex", "[0:v]" + overlay_filter + "[vout]",
            "-map", "[vout]", "-map", "1:a",
            "-c:v", "libx264", "-preset", "fast", "-crf", "23",
            "-c:a", "aac", "-b:a", "128k",
            "-shortest",
            out_path
        ])
    else:
        cmd.extend([
            "-vf", overlay_filter,
            "-c:v", "libx264", "-preset", "fast", "-crf", "23",
            "-an",
            out_path
        ])
    r = run(cmd, timeout=180)
    if r.returncode != 0:
        print("  Overlay render failed: " + r.stderr[:500])
        # Fallback: just use trimmed video
        shutil.copy2(trimmed_path, out_path)
else:
    if narration_path and os.path.exists(narration_path):
        r = run(["ffmpeg", "-y", "-i", trimmed_path, "-i", narration_path,
                 "-c:v", "copy", "-c:a", "aac", "-shortest", out_path], timeout=60)
        if r.returncode != 0:
            shutil.copy2(trimmed_path, out_path)
    else:
        shutil.copy2(trimmed_path, out_path)

final_dur = get_duration(out_path)
final_size = os.path.getsize(out_path) if os.path.exists(out_path) else 0
print("\n=== Result ===")
print("  Final video: {} bytes, {:.1f}s".format(final_size, final_dur))
print("  Trimmed: {:.1f}s of launch removed".format(trim_start))
print("  Overlays: {} text segments".format(len(drawtext_parts)))
print("  Narration: {}".format("yes" if narration_path and os.path.exists(narration_path) else "no"))

# Write processing metadata
meta = {
    "trim_start_sec": trim_start,
    "trimmed_duration_sec": trimmed_dur,
    "final_duration_sec": final_dur,
    "final_size_bytes": final_size,
    "overlay_count": len(drawtext_parts),
    "narration_segments": len(narration_segments),
    "interactions": len(interactions),
    "annotations": [{"start": a["start"], "scenario": a["scenario"],
                     "result": a["result"], "duration": a["duration"],
                     "vo": a.get("vo_announcements", [])} for a in annotations]
}
meta_path = os.path.join(os.path.dirname(out_path), "video_metadata.json")
with open(meta_path, "w") as f:
    json.dump(meta, f, indent=2)
print("  Metadata: " + meta_path)

# Cleanup
shutil.rmtree(work_dir, ignore_errors=True)
