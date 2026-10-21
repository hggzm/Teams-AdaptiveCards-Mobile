#!/usr/bin/env python3
"""Validate a11y transcript against expected VoiceOver behavior."""
import json, sys, os

transcript_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-recordings/transcript.json"

with open(transcript_path) as f:
    data = json.load(f)

errors = []
warnings = []
passed = 0

for entry in data["transcript"]:
    test = entry["test_name"]
    result = entry["result"]
    exp = entry.get("expected", {})

    if result != "passed":
        errors.append("FAIL: {} result={} (expected passed)".format(test, result))
        continue

    announcements = exp.get("announcements", [])
    if not announcements:
        warnings.append("WARN: {} has no expected announcements defined".format(test))
        continue

    for ann in announcements:
        if ann.get("hidden"):
            passed += 1
            continue
        if "label" not in ann:
            errors.append("FAIL: {} announcement missing label: {}".format(test, ann))
        else:
            passed += 1
        if "value" in ann:
            passed += 1

print("Transcript Validation Results:")
print("  Checks passed: {}".format(passed))
print("  Errors: {}".format(len(errors)))
print("  Warnings: {}".format(len(warnings)))

for e in errors:
    print("  ::error::{}".format(e))
for w in warnings:
    print("  {}".format(w))

out_dir = os.path.dirname(transcript_path)
with open(os.path.join(out_dir, "validation.json"), "w") as f:
    json.dump({
        "passed": passed,
        "errors": len(errors),
        "warnings": len(warnings),
        "error_details": errors,
        "warning_details": warnings,
        "verdict": "PASS" if len(errors) == 0 else "FAIL"
    }, f, indent=2)

if errors:
    print("::error::Transcript validation failed")
    sys.exit(1)
else:
    print("Transcript validation PASSED")
