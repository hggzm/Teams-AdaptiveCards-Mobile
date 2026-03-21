# Accessibility Screenshot & Automation Pipeline

## Overview

This fork (`hggzm/Teams-AdaptiveCards-Mobile`) has automated accessibility validation pipelines for both iOS and Android. These pipelines capture accessibility element data from real OS APIs, generate annotated screenshots with numbered bounding boxes, and produce VoiceOver/TalkBack transcripts — all in CI.

## Quick Start

### Trigger the iOS Pipeline
```bash
cd ~/code/Teams-AdaptiveCards-Mobile
git checkout proxy/integration
# Edit source/ios/** or .github/workflows/axe-a11y-pipeline.yml
git push origin proxy/integration
# Monitor:
gh run list --repo hggzm/Teams-AdaptiveCards-Mobile --limit 5 | grep "AXe A11y"
```

### Trigger the Android Pipeline
```bash
git checkout proxy/integration
# Edit source/android/** or .github/workflows/a11y-screenshot-gate.yml
git push origin proxy/integration
# Monitor:
gh run list --repo hggzm/Teams-AdaptiveCards-Mobile --limit 5 | grep "A11y Screenshot"
```

### View Results
- **Gallery**: https://hggzm.github.io/Teams-AdaptiveCards-Mobile/
- **Artifacts**: Download from GitHub Actions run page

---

## iOS Pipeline

### Workflow: `.github/workflows/axe-a11y-pipeline.yml`
- **Runner**: `macos-15`
- **Triggers**: push to `proxy/**` when `source/ios/**` or workflow changes

### What It Does
1. Boots iOS Simulator (dynamic device discovery)
2. Installs AXe CLI (`brew install cameroncooke/axe/axe`) for video recording
3. Builds ADCIOSVisualizer for testing (`xcodebuild build-for-testing`)
4. Starts AXe video recording (`axe record-video --fps 15`)
5. Runs XCUITests that dump the accessibility tree (`testA11yDumpActivityUpdateShowCard`, `testA11yAutomation_*`)
6. Stops recording
7. Post-processes: draws green overlay boxes with Pillow, generates transcript JSON
8. Deploys to GitHub Pages

### Test Methods

#### `testA11yDumpActivityUpdateShowCard` (screenshot + a11y dump)
Opens ActivityUpdate card, captures accessibility tree + screenshot before and after ShowCard expand.

#### `testA11yAutomation_ActivityUpdate` (a11y-driven automation)
Navigates the app using ONLY accessibility labels:
```objc
[self navigateToCardByA11y:@"v1.5" type:@"Scenarios" card:@"ActivityUpdate.json"];
[self tapByAccessibilityLabel:@"Comment"];
NSArray *elements = [self discoverAccessibleElements]; // VoiceOver reading order
```

#### `testA11yAutomation_ExpenseReport`
Same pattern for ExpenseReport card — discovers Reject/Approve buttons via labels.

#### `testA11yAutomation_InputForm`
Discovers textField/textView elements on input cards.

### Helper Methods (ADCIOSVisualizerUITests.mm)

| Method | Purpose |
|--------|---------|
| `discoverAccessibleElements` | Query all VoiceOver elements, sorted in reading order |
| `tapByAccessibilityLabel:` | Find and tap by accessibility label (no coordinates) |
| `navigateToCardByA11y:type:card:` | Navigate app menus via labels only |
| `saveA11yState:` | Capture element JSON + screenshot |

### In-App Inspector (ViewController.m)
Green "A11y" button in the Visualizer toolbar. Uses native UIAccessibility APIs inside the app process:
- `walkAccessibilityTree:` — traverses `isAccessibilityElement`, `accessibilityElements`, `accessibilityElementAtIndex:`
- `showAccessibilityOverlay` — draws green boxes at `accessibilityFrame` coordinates
- `activateElementByLabel:inView:` — uses `accessibilityActivate()` (VoiceOver's double-tap)

### Testing Different Cards
Modify `testA11yDumpActivityUpdateShowCard` in `ADCIOSVisualizerUITests.mm`:
```objc
// Change card name:
[self openCardForVersion:@"v1.5" forCardType:@"Scenarios" withCardName:@"ExpenseReport.json"];
```

### Key Scripts
| File | Purpose |
|------|---------|
| `.github/scripts/a11y_axe_pipeline.py` | Main pipeline orchestrator |
| `.github/scripts/a11y_gallery.py` | HTML gallery generator |
| `.github/scripts/a11y_transcript.py` | Transcript generator |
| `.github/scripts/a11y_validate.py` | Transcript validator |

### Artifacts Produced
- `activity_card_rendered.png` — raw screenshot
- `annotated_activity_card_rendered.png` — with green a11y overlay boxes
- `a11y_transcript.json` — per-element VoiceOver reads
- `voiceover_demo.mp4` — video of test interactions
- `narr_*.aiff` — VoiceOver narration audio (macOS `say`)

---

## Android Pipeline

### Workflow: `.github/workflows/a11y-screenshot-gate.yml`
- **Runner**: `ubuntu-latest` with Android emulator (API 29)
- **Triggers**: push to `proxy/**` when `source/android/**` or workflow changes

### What It Does
1. Builds uitestapp + adaptivecards SDK
2. Starts Android emulator with TalkBack enabled
3. Starts screen recording (`adb shell screenrecord`)
4. Runs AccessibilityScreenshotTests (9 scenarios)
5. Walks AccessibilityNodeInfo tree via `UiAutomation.getRootInActiveWindow()`
6. Takes in-test screenshots via `screencap`
7. Annotates with Pillow overlays + generates TTS narration
8. Deploys to GitHub Pages

### Test Scenarios (AccessibilityScreenshotTests.kt)
| Scenario | Card | What It Tests |
|----------|------|---------------|
| `showcard_collapsed` | ExpenseReport | ShowCard button before expand |
| `showcard_expanded` | ExpenseReport | ShowCard with `stateDescription=expanded` |
| `validation_empty_form` | Input.Text.ErrorMessage | Form before submit |
| `validation_error_visible` | Input.Text.ErrorMessage | Error announced to TalkBack |
| `toggle_visibility_hidden` | ExpenseReport | History rows hidden |
| `toggle_visibility_revealed` | ExpenseReport | History rows revealed |
| `activity_showcard_buttons` | ActivityUpdate | Action buttons |
| `activity_showcard_expanded` | ActivityUpdate | Comment ShowCard expanded |

### A11yNavigator (source/android/.../A11yNavigator.kt)
Kotlin helper for accessibility-driven navigation:
```kotlin
val nav = A11yNavigator(instrumentation)
nav.navigateToCard("v1.5", "Scenarios", "ActivityUpdate.json")
nav.tapByLabel("Comment")  // Uses AccessibilityNodeInfo tree
val elements = nav.discoverElements()  // TalkBack reading order
```

### Live TalkBack Overlay
`walkAccessibilityFocus()` calls `performAction(ACTION_ACCESSIBILITY_FOCUS)` on each element, causing TalkBack to render its green focus rectangle. The video captures this.

### Annotation Script: `scripts/annotate_a11y.py`
Draws numbered green overlay boxes on screenshots from XML/TXT accessibility tree data.

### Artifacts Produced
- `android_a11y_*.png` — raw screenshots per scenario
- `annotated/*.png` — with green numbered overlays
- `a11y_transcript.json` — per-scenario element list
- `android_a11y_talkback_recording.mp4` — TalkBack screen recording
- `*_narration.wav` — TTS audio per scenario

---

## Element Data Sources

Both pipelines use **real OS accessibility APIs** — the same data VoiceOver/TalkBack consume:

### iOS
| Property | API | What VoiceOver Does |
|----------|-----|---------------------|
| Label | `accessibilityLabel` | Reads this aloud |
| Value | `accessibilityValue` | Reads after label |
| Hint | `accessibilityHint` | "Double tap to..." |
| Frame | `accessibilityFrame` | Focus rectangle bounds |
| Traits | `accessibilityTraits` | "Button", "Header", etc. |

### Android
| Property | API | What TalkBack Does |
|----------|-----|---------------------|
| contentDescription | `AccessibilityNodeInfo` | Reads this aloud |
| text | `AccessibilityNodeInfo` | Fallback if no contentDescription |
| stateDescription | `AccessibilityNodeInfo` | "Expanded", "Collapsed" |
| bounds | `getBoundsInScreen()` | Focus rectangle bounds |
| className | `AccessibilityNodeInfo` | Role announcement |

---

## Branch Index

All branches are merged to `proxy/integration`:

| Branch | Purpose |
|--------|---------|
| `proxy/integration` | **Stable** — all work merged |
| `proxy/add-ios-a11y-screenshots` | iOS screenshot pipeline |
| `proxy/a11y-driven-automation` | iOS a11y-driven navigation + in-app inspector |
| `proxy/a11y-navigator` | Android A11yNavigator |
| `proxy/add-android-a11y-screenshots` | Android screenshot pipeline |
| `proxy/a11y-with-fixes` | Android + SDK fixes (PRs #662/#663) |
| `proxy/a11y-live-overlay` | Android TalkBack live focus overlay |

---

## CI Workflows

| Workflow | Platform | Trigger |
|----------|----------|---------|
| `axe-a11y-pipeline.yml` | iOS | `source/ios/**` changes |
| `a11y-screenshot-gate.yml` | Android | `source/android/**` changes |
| `agent-gate.yml` | Both | SPM/Gradle builds + visual tests |
| `sdk-build-gate.yml` | Both | SDK compilation check |
| `a11y-probe.yml` | iOS | Simulator capability diagnostic |

---

## Posting PR Screenshots

To post accessibility validation to upstream PRs:
```bash
# Use GitHub Pages URLs (already deployed)
PAGES="https://hggzm.github.io/Teams-AdaptiveCards-Mobile"

# Post on upstream PR
gh pr comment <PR#> --repo microsoft/Teams-AdaptiveCards-Mobile \
  --body "## VoiceOver Validation
![Annotated]($PAGES/annotated_auto_activity_initial.png)
[Transcript]($PAGES/a11y_transcript.json)"
```
