#!/usr/bin/env python3
"""Generate narrated audio from a11y transcript using macOS say."""
import json, subprocess, os, sys, shutil

transcript_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-recordings/transcript.json"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/a11y-recordings"
segments_dir = os.path.join(out_dir, "audio_segments")
os.makedirs(segments_dir, exist_ok=True)

with open(transcript_path) as f:
    data = json.load(f)

concat_list = []
for i, entry in enumerate(data["transcript"]):
    exp = entry.get("expected", {})
    scenario = exp.get("scenario", entry["test_name"])
    announcements = exp.get("announcements", [])

    lines = ["Scenario: {}.".format(scenario)]
    for ann in announcements:
        if ann.get("hidden"):
            lines.append("{} is hidden from VoiceOver.".format(ann["element"]))
        else:
            label = ann.get("label", "")
            value = ann.get("value", "")
            traits = ann.get("traits", "")
            speech = label
            if value:
                speech += ", {}".format(value)
            if traits:
                speech += ". {}.".format(traits)
            lines.append(speech)
        if ann.get("note"):
            lines.append(ann["note"])

    narration_text = " ".join(lines)
    segment_file = os.path.join(segments_dir, "segment_{:02d}.aiff".format(i))

    result = subprocess.run(
        ["say", "-v", "Samantha", "-r", "180", "-o", segment_file, narration_text],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0 and os.path.exists(segment_file):
        concat_list.append(segment_file)
        print("  Segment {}: {} chars -> {} bytes".format(i, len(narration_text), os.path.getsize(segment_file)))
    else:
        print("  Segment {}: say failed: {}".format(i, result.stderr))

if concat_list:
    # Try ffmpeg first, fall back to sox or simple concatenation
    narration_path = os.path.join(out_dir, "narration.aiff")

    # Check what tools are available
    has_ffmpeg = shutil.which("ffmpeg") is not None
    has_sox = shutil.which("sox") is not None

    if has_ffmpeg:
        # Create silence
        subprocess.run(["say", "-v", "Samantha", "-o",
                        os.path.join(segments_dir, "silence.aiff"), " "],
                       capture_output=True, timeout=10)

        # Build ffmpeg concat
        filter_inputs = []
        silence = os.path.join(segments_dir, "silence.aiff")
        for i, seg in enumerate(concat_list):
            filter_inputs.extend(["-i", seg])
            if i < len(concat_list) - 1:
                filter_inputs.extend(["-i", silence])

        total_inputs = len(concat_list) * 2 - 1
        concat_filter = "".join("[{}:a]".format(i) for i in range(total_inputs))
        concat_filter += "concat=n={}:v=0:a=1[aout]".format(total_inputs)

        cmd = ["ffmpeg", "-y"] + filter_inputs + [
            "-filter_complex", concat_filter,
            "-map", "[aout]", narration_path
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            print("Narration (ffmpeg): {} bytes".format(os.path.getsize(narration_path)))
        else:
            print("ffmpeg failed, falling back to first segment")
            shutil.copy2(concat_list[0], narration_path)
    elif has_sox:
        # sox can concatenate audio files
        cmd = ["sox"] + concat_list + [narration_path]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            print("Narration (sox): {} bytes".format(os.path.getsize(narration_path)))
        else:
            shutil.copy2(concat_list[0], narration_path)
    else:
        # No audio tools - use afconvert (always available on macOS)
        # Convert each segment to CAF, concatenate raw PCM, convert back
        print("No ffmpeg/sox found, using afconvert for concatenation")
        pcm_parts = []
        for seg in concat_list:
            pcm_path = seg.replace(".aiff", ".pcm")
            result = subprocess.run(
                ["afconvert", "-f", "caff", "-d", "LEI16", "-c", "1", seg, pcm_path],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                pcm_parts.append(pcm_path)
                # Add 0.5s silence (16000 samples * 2 bytes = 32000 bytes of zeros at 16kHz)
                silence_path = seg.replace(".aiff", ".silence")
                with open(silence_path, "wb") as sf:
                    sf.write(b'\x00' * 16000)
                pcm_parts.append(silence_path)

        if pcm_parts:
            # Concatenate all PCM data
            combined_pcm = os.path.join(segments_dir, "combined.pcm")
            with open(combined_pcm, "wb") as out:
                for pp in pcm_parts:
                    with open(pp, "rb") as inp:
                        out.write(inp.read())

            # Convert back to AIFF
            result = subprocess.run(
                ["afconvert", "-f", "AIFF", "-d", "BEI16", "-r", "16000", "-c", "1",
                 combined_pcm, narration_path],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                print("Narration (afconvert): {} bytes".format(os.path.getsize(narration_path)))
            else:
                print("afconvert concat failed: {}".format(result.stderr[:200]))
                # Last resort: just use the longest segment
                biggest = max(concat_list, key=os.path.getsize)
                shutil.copy2(biggest, narration_path)
        else:
            shutil.copy2(concat_list[0], narration_path)

    print("NARRATION_READY")
else:
    print("No segments generated")
