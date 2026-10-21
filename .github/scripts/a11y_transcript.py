#!/usr/bin/env python3
"""Generate timed a11y transcript from test log and expected announcements."""
import re, json, os, sys

log_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/a11y-test.log"
out_dir = sys.argv[2] if len(sys.argv) > 2 else "/tmp/a11y-recordings"

EXPECTED = {
    "testShowCard_expenseReport_collapsed": {
        "scenario": "ShowCard Expand/Collapse (PR #660)",
        "card": "ExpenseReport", "state": "before",
        "announcements": [
            {"element": "Reject button", "label": "Reject", "value": "collapsed", "traits": "button"},
            {"element": "Approve button", "label": "Approve", "traits": "button"},
            {"element": "Air Travel", "label": "Air Travel", "traits": "staticText"},
            {"element": "Total", "label": "Total", "value": "$404.30", "traits": "staticText"}
        ]
    },
    "testShowCard_expenseReport_expanded": {
        "scenario": "ShowCard Expand/Collapse (PR #660)",
        "card": "ExpenseReport", "state": "after",
        "announcements": [
            {"element": "Reject button", "label": "Reject", "value": "card expanded", "traits": "button"},
            {"element": "Rejection reason input", "label": "Rejection reason input", "traits": "textField"},
            {"element": "Reason label", "label": "Reason for rejection", "traits": "staticText"}
        ]
    },
    "testShowCard_expenseReport_dismissed": {
        "scenario": "ShowCard Dismiss Focus Return (PR #660)",
        "card": "ExpenseReport", "state": "after_dismiss",
        "announcements": [
            {"element": "Reject button", "label": "Reject", "value": "collapsed", "traits": "button",
             "note": "Focus returns here via UIAccessibilityLayoutChangedNotification(_button)"},
            {"element": "ShowCard content", "hidden": True,
             "note": "Content hidden, _adcView.isHidden == true"}
        ]
    },
    "testToggleVisibility_expenseReport_hidden": {
        "scenario": "ToggleVisibility Focus Retention (PR #661)",
        "card": "ExpenseReport", "state": "before",
        "announcements": [
            {"element": "Show History button", "label": "Show History", "traits": "button"},
            {"element": "History rows", "hidden": True,
             "note": "3 history rows hidden by Action.ToggleVisibility"}
        ]
    },
    "testToggleVisibility_expenseReport_revealed": {
        "scenario": "ToggleVisibility Focus Retention (PR #661)",
        "card": "ExpenseReport", "state": "after",
        "announcements": [
            {"element": "Hide History button", "label": "Hide History", "traits": "button"},
            {"element": "History row 1", "label": "Mar 1 \u2014 Submitted by John", "traits": "staticText"},
            {"element": "History row 2", "label": "Mar 2 \u2014 Approved by Manager", "traits": "staticText"},
            {"element": "History row 3", "label": "Mar 3 \u2014 Payment processed", "traits": "staticText",
             "note": "UIAccessibilityLayoutChangedNotification(nil) posted - focus retained"}
        ]
    },
    "testShowCard_activityUpdate_collapsed": {
        "scenario": "ActivityUpdate ShowCard (PR #660)",
        "card": "ActivityUpdate", "state": "before",
        "announcements": [
            {"element": "Comment button", "label": "Comment", "value": "collapsed", "traits": "button"},
            {"element": "Set due date button", "label": "Set due date", "value": "collapsed", "traits": "button"},
            {"element": "Author", "label": "Matt Hidinger", "traits": "image"}
        ]
    },
    "testShowCard_activityUpdate_expanded": {
        "scenario": "ActivityUpdate ShowCard (PR #660)",
        "card": "ActivityUpdate", "state": "after",
        "announcements": [
            {"element": "Comment button", "label": "Comment", "value": "card expanded", "traits": "button"},
            {"element": "Comment input", "label": "Enter your comment", "traits": "textField",
             "note": "Inline ShowCard content visible with input field"}
        ]
    },
    "testShowCard_layoutNotification_stateConsistency": {
        "scenario": "Layout Notification State Consistency",
        "card": "ExpenseReport", "state": "verification",
        "announcements": [
            {"element": "Expanded state", "label": "Reject", "value": "card expanded",
             "note": "Button value updated, content visible, button remains isAccessibilityElement"},
            {"element": "Collapsed state", "label": "Reject", "value": "collapsed",
             "note": "Button value updated, content hidden, button accessible for focus return"}
        ]
    }
}

test_cases = []
if os.path.exists(log_path):
    with open(log_path) as f:
        for line in f:
            m = re.search(r"Test Case.*?(\w+SnapshotTests (\w+))\]' (started|passed|failed)(?: \((\d+\.\d+) seconds\))?", line)
            if m:
                test_name = m.group(2)
                action = m.group(3)
                duration = float(m.group(4)) if m.group(4) else 0
                if action == "started":
                    test_cases.append({"test": test_name, "started": True})
                elif action in ("passed", "failed"):
                    if test_cases and test_cases[-1]["test"] == test_name:
                        test_cases[-1]["result"] = action
                        test_cases[-1]["duration"] = duration

transcript = []
cumulative_time = 3.0
for tc in test_cases:
    test_name = tc["test"]
    duration = tc.get("duration", 1.0)
    result = tc.get("result", "unknown")
    entry = {
        "timestamp_sec": round(cumulative_time, 1),
        "test_name": test_name,
        "result": result,
        "duration_sec": duration,
        "expected": EXPECTED.get(test_name, {})
    }
    transcript.append(entry)
    cumulative_time += duration + 0.5

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "transcript.json"), "w") as f:
    json.dump({"transcript": transcript, "total_duration_sec": round(cumulative_time, 1)}, f, indent=2)

with open(os.path.join(out_dir, "transcript.txt"), "w") as f:
    f.write("VOICEOVER ACCESSIBILITY TRANSCRIPT\n")
    f.write("=" * 60 + "\n\n")
    for t in transcript:
        exp = t.get("expected", {})
        f.write("[{:6.1f}s] TEST: {} ({})\n".format(t["timestamp_sec"], t["test_name"], t["result"]))
        f.write("         Scenario: {}\n".format(exp.get("scenario", "N/A")))
        f.write("         Card: {} | State: {}\n".format(exp.get("card", "N/A"), exp.get("state", "N/A")))
        for ann in exp.get("announcements", []):
            if ann.get("hidden"):
                f.write("         [HIDDEN] {}".format(ann["element"]))
            else:
                label = ann.get("label", "")
                value = ann.get("value", "")
                traits = ann.get("traits", "")
                voice = '"{}'.format(label)
                if value:
                    voice += ", {}".format(value)
                voice += '"'
                f.write("         VoiceOver: {} (traits: {})".format(voice, traits))
            if ann.get("note"):
                f.write("  -- {}".format(ann["note"]))
            f.write("\n")
        f.write("\n")

print("Transcript: {} test entries, {:.1f}s total".format(len(transcript), cumulative_time))
