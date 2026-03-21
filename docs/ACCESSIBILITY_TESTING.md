# Accessibility Testing & Automation Guide

This documents the accessibility (a11y) testing infrastructure on the `proxy/integration` branch of `hggzm/Teams-AdaptiveCards-Mobile` (fork).

## Quick Start

### Trigger the Android A11y Pipeline
```bash
# Push any change to a proxy/** branch touching source/android/ or samples/
git push origin proxy/integration

# Or trigger manually via GitHub Actions UI:
# Go to: https://github.com/hggzm/Teams-AdaptiveCards-Mobile/actions/workflows/a11y-screenshot-gate.yml
# Click "Run workflow" → select branch
```

### Trigger the iOS A11y Pipeline
```bash
# Push any change to a proxy/** branch touching source/ios/ or samples/
git push origin proxy/integration

# Workflows: a11y-screenshot-gate.yml, a11y-probe.yml, axe-a11y-pipeline.yml
```

## Architecture

### Android

```
AccessibilityScreenshotTests.kt  — 9 in-test screenshot scenarios
A11yNavigatorTests.kt             — 4 accessibility-driven automation tests
A11yNavigator.kt                  — Test helper: find/tap elements by a11y label
A11yInspector.kt                  — Runtime inspector (works in main app)
A11yOverlayView.kt                — Transparent overlay drawing green a11y boxes
scripts/annotate_a11y.py          — Post-process: numbered overlays + TTS
```

### iOS

```
A11yInteractionSnapshotTests.swift — Snapshot tests with VoiceOver state capture
.github/scripts/a11y_axe_pipeline.py — AXe-based a11y automation
.github/scripts/a11y_postprocess.py  — Gallery + transcript generation
```

## Android A11y Pipeline Details

### Workflow: `.github/workflows/a11y-screenshot-gate.yml`

**Triggers**: Push/PR to `proxy/**` branches with changes in `source/android/**`, `source/shared/**`, or `samples/**`

**Steps**:
1. Build uitestapp + adaptivecards SDK (with native C++ lib)
2. Boot API 29 `google_apis` emulator with TalkBack enabled
3. Start screen recording (`screenrecord --time-limit 180`)
4. Run `AccessibilityScreenshotTests` (9 tests, single gradle invocation)
5. Run `A11yNavigatorTests` (4 tests, accessibility-driven automation)
6. Stop recording, pull screenshots + video + a11y element data
7. Validate: screenshot uniqueness, video moov atom, frame diversity
8. Annotate screenshots with numbered green overlays + TTS narration
9. Upload artifacts + deploy to GitHub Pages

### Test Scenarios

| Test | Card | What It Validates |
|---|---|---|
| `a11y_showcard_collapsed` | ExpenseReport.json | Reject button visible, ShowCard hidden |
| `a11y_showcard_expanded` | ExpenseReport.json | ShowCard expanded after tap, rejection reason input visible |
| `a11y_showcard_collapsed_again` | ExpenseReport.json | ShowCard collapsed after second tap |
| `a11y_validation_empty_form` | InputForm.json | Empty form before submit |
| `a11y_validation_error_visible` | InputForm.json | Error messages visible after submit |
| `a11y_toggle_visibility_hidden` | ExpenseReport.json | "Show history" text visible |
| `a11y_toggle_visibility_revealed` | ExpenseReport.json | After toggle: content revealed |
| `a11y_activity_showcard_buttons` | ActivityUpdate.json | ShowCard buttons displayed |
| `a11y_activity_showcard_expanded` | ActivityUpdate.json | Comment ShowCard expanded |

### A11yNavigator Tests (accessibility-driven automation)

| Test | Card | What It Proves |
|---|---|---|
| `nav_expense_report_showcard_workflow` | ExpenseReport.json | Full ShowCard workflow via a11y labels only |
| `nav_input_form_validation_workflow` | InputForm.json | Submit + verify errors via a11y labels |
| `nav_activity_update_comment_workflow` | ActivityUpdate.json | Multi-ShowCard navigation via a11y labels |
| `nav_element_inventory` | ExpenseReport.json | 20+ accessible elements discoverable |

### Artifacts

The `a11y-android-screenshots` artifact contains:
- `android_a11y_*.png` — Raw screenshots (taken INSIDE tests while card is on screen)
- `android_a11y_nav_*.png` — Navigator test screenshots
- `annotated/*.png` — Screenshots with numbered green a11y overlays
- `android_a11y_talkback_recording.mp4` — TalkBack screen recording
- `a11y_transcript.json` — 414+ a11y nodes with labels + bounds per scenario

## How to Add a New Test Card

### Android

1. The card must be in `samples/v1.5/Scenarios/` (already included in uitestapp assets)

2. Add a test in `AccessibilityScreenshotTests.kt`:
```kotlin
@Test
fun a11y_your_scenario() {
    renderCard("YourCard.json")
    // Optional: interact with the card
    Espresso.onView(ViewMatchers.withText("Button Text"))
        .perform(ViewActions.scrollTo(), ViewActions.click())
    Thread.sleep(1000)
    takeNamedScreenshot("your_scenario")
}
```

3. Or add an A11yNavigator test for accessibility-driven automation:
```kotlin
@Test
fun nav_your_workflow() {
    renderCard("YourCard.json")

    // Find and interact via a11y labels ONLY
    val btn = nav.findByLabel("Button Text")
    assertNotNull("Button should be findable by label", btn)
    nav.tapByLabel("Button Text")
    Thread.sleep(1500)

    // Verify expected elements appear
    val result = nav.findByLabel("Expected Result")
    assertNotNull("Result should appear", result)

    screencap("your_workflow")
}
```

4. Push to a `proxy/**` branch — pipeline triggers automatically

### iOS

Add a test in `A11yInteractionSnapshotTests.swift` following the existing pattern.

## A11yNavigator API Reference (Test-only)

```kotlin
val nav = A11yNavigator()

// Find elements by accessibility label
nav.findByLabel("Reject")           // First match
nav.findAllByLabel("error")         // All matches
nav.findByState("expanded")         // By stateDescription (API 30+)
nav.findByClass("Button")           // By class name

// Interact
nav.tapByLabel("Submit")            // Tap by label (returns Boolean)

// Inspect
nav.listElements()                  // All TalkBack-visible elements
nav.walkFocus("scenario", 80)       // Walk focus with green rectangles
nav.logElements("scenario")         // Dump to logcat for CI extraction

// Capture
nav.screenshot("name")              // Screencap to pullable path
```

## A11yInspector API Reference (Runtime — works in main app)

```kotlin
// Get from RenderedCardFragment
val inspector = renderedCardFragment.getA11yInspector()

// Same discovery API as A11yNavigator
inspector?.findByLabel("Reject")?.tap()
inspector?.tapByLabel("Submit")
inspector?.listElements()

// Visual overlay
renderedCardFragment.toggleA11yOverlay()  // Show/hide green rectangles

// Diagnostics
inspector?.printTree()               // Full a11y tree to logcat
inspector?.toJson()                  // JSON export
inspector?.drawOverlays(canvas)      // Custom overlay rendering
```

### Key Difference: A11yNavigator vs A11yInspector

| | A11yNavigator | A11yInspector |
|---|---|---|
| Location | `androidTest/` | `main/` app |
| Backend | `UiAutomation.getRootInActiveWindow()` | `View.createAccessibilityNodeInfo()` |
| Use | CI pipeline, instrumented tests | Runtime inspection, debugging |
| Overlay | TalkBack focus rectangle | Custom `A11yOverlayView` |

## Upstream PR Validation

To validate an upstream a11y fix PR:

1. The fix must already be applied in `proxy/integration` (or a branch off it)
2. Run the pipeline — it captures screenshots + a11y tree
3. Download artifacts from the CI run
4. Post comment on the upstream PR:
```bash
gh pr comment <PR#> --repo microsoft/Teams-AdaptiveCards-Mobile \
  --body "## ♿ TalkBack Validation
  Verified via automated a11y pipeline.
  **Pipeline**: [CI run XXXXX](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/actions/runs/XXXXX)
  **Tests**: 9 screenshot + 4 navigator — all passing"
```

## Branch Hierarchy

```
proxy/integration (stable, all features merged)
  ├── proxy/add-android-a11y-screenshots (foundation — merged)
  │   └── proxy/a11y-with-fixes (SDK fixes #662/#663 — merged)
  │       └── proxy/a11y-live-overlay (TalkBack focus in video — merged)
  ├── proxy/a11y-navigator (A11yNavigator + A11yInspector — merged)
  ├── proxy/add-ios-a11y-screenshots (iOS pipeline — merged)
  └── proxy/validate-upstream-fixes (upstream PR validation)
```
