# Proxy ? Upstream PR Tracking Log

Track every PR merged into `proxy/integration` that needs replication to
`microsoft/Teams-AdaptiveCards-Mobile` main.

## Status Legend

| Status | Meaning |
|--------|---------|
| `pending` | Merged to proxy; not yet proposed upstream |
| `upstream-pr` | PR opened against upstream |
| `merged` | Upstream PR merged |
| `skipped` | Proxy-only (CI config, docs) ? no upstream PR needed |

## Tracking Table

| # | Proxy PR | Date | Title | Commit | Status | Fork PR (clean) | Upstream PR |
|---|----------|------|-------|--------|--------|-----------------|-------------|
| 1 | ? | 2025-01-18 | ci: add agent validation gate | `04ff142d` | skipped | ? | CI-only, not applicable to upstream |
| 2 | ? | 2025-01-18 | ci: skip invalid test JSON files | `b4c4ef0b` | skipped | ? | CI-only |
| 3 | ? | 2025-01-18 | docs: add proxy branch tracker | `6117dc06` | skipped | ? | Docs-only |
| 4 | ? | 2025-01-18 | ci: upgrade gate with visual regression | `3eb25eee` | skipped | ? | CI-only |
| 5 | ? | 2026-03-01 | docs: add proxy workflow guide + PR log | `d798b829` | skipped | ? | Docs-only |
| 6 | #14 | 2026-03-01 | docs: add descriptive comment to SharedAdaptiveCard.cpp | `7bd23944` | upstream-pr | ? | [#508](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/508) |
| 7 | #23 | 2025-07-15 | fix: add Image role for TalkBack on ImageView elements | `49868ff1` | upstream-pr | [#30](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/30) | [#518](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/518) |
| 8 | #24 | 2025-07-15 | fix: prevent TalkBack from announcing both Link and Button for OpenUrl | `c68a8b2a` | upstream-pr | [#31](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/31) | [#519](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/519) |
| 9 | #25 | 2025-07-15 | fix: announce error messages to TalkBack on validation failure | `d2275edc` | upstream-pr | [#32](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/32) | [#520](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/520) |
| 10 | #26 | 2025-07-15 | fix: correct TalkBack dropdown item count to exclude hidden placeholder | `90947278` | upstream-pr | [#33](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/33) | [#521](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/521) |
| 11 | #27 | 2025-07-15 | fix: prevent RadioGroup from aggregating child labels for TalkBack | `bd7eae63` | upstream-pr | [#34](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/34) | [#522](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/522) |
| 12 | #28 | 2025-07-15 | fix: ShowCard toggle announces expanded/collapsed instead of selected | `027675eb` | upstream-pr | [#35](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/35) | [#523](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/523) |
| 13 | #29 | 2025-07-15 | fix: render ProgressBar with accessible role and value info for TalkBack | `e338d0ef` | upstream-pr | [#36](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/36) | [#524](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/524) |

## Clean Branch Strategy

Entries 7-13 originally used `proxy/fix-*` branches (based on `proxy/integration`) for upstream PRs.
This caused upstream PRs to show 947+ lines / 6 files because the branch included proxy docs, CI workflow, and SharedAdaptiveCard.cpp comment changes.

**Fix applied:** Created `clean/fix-*` branches from `upstream/main` with only the cherry-picked fix commit.
Each clean branch shows exactly **1 file changed** with only the accessibility fix code.

| Clean Branch | File Changed | Changes |
|---|---|---|
| `clean/fix-image-role-accessibility` | ImageRenderer.java | +13 |
| `clean/fix-openurl-duplicate-role` | ActionElementRenderer.java | +14/-1 |
| `clean/fix-error-message-accessibility` | StretchableInputLayout.java | +8/-1 |
| `clean/fix-dropdown-index-count` | ChoiceSetInputRenderer.java | +2/-1 |
| `clean/fix-choiceset-group-labels` | ChoiceSetInputRenderer.java | +4 |
| `clean/fix-showcard-toggle-a11y` | BaseActionElementRenderer.java | +8/-1 |
| `clean/fix-progress-bar-accessibility` | ProgressBarRenderer.kt | +57/-1 |

Fork PRs #30-#36 use these clean branches and target `main` (which is exactly `upstream/main`).
Upstream PRs #518-#524 use the same clean branches. All verified to show exactly 1 file changed.

---

## How to Add an Entry

When a PR is merged into `proxy/integration`, add a new row:

```markdown
| <next_#> | #<pr_number> | YYYY-MM-DD | <title> | `<short_hash>` | pending | ? | ? |
```

When a clean fork PR is created:

```markdown
| <#> | ... | ... | ... | ... | pending | [#NN](url) | ? |
```

When the upstream PR is created:

```markdown
| <#> | ... | ... | ... | ... | upstream-pr | [#NN](url) | [#NNN](url) |
```

When merged upstream:

```markdown
| <#> | ... | ... | ... | ... | merged | [#NN](url) | [#NNN](url) |
```

## Batch 2b ? iOS Accessibility Fixes (PRs #525-#531)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 14 | #166/#165 | proxy/fix-showcard-focus-166 | clean/fix-showcard-focus-166 | [#525](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/525) | Post VoiceOver notification on ShowCard expand/collapse |
| 15 | #34 | proxy/fix-togglevisibility-focus-34 | clean/fix-togglevisibility-focus-34 | [#526](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/526) | Post VoiceOver notification after ToggleVisibility |
| 16 | #493 | proxy/fix-error-announce-493 | clean/fix-error-announce-493 | [#527](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/527) | Announce validation error messages to TalkBack |
| 17 | #164 | ? | clean/fix-group-announcement-164 | [#528](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/528) | Prevent VoiceOver "Group" on containers with selectAction |
| 18 | #173 | ? | clean/fix-choiceset-selected-173 | [#529](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/529) | Announce "selected" state for ChoiceSet compact items |
| 19 | #100 | ? | clean/fix-showcard-announce-100 | [#530](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/530) | Announce expanded/collapsed state for ShowCard actions |
| 20 | #12/#108 | ? | clean/fix-hidden-focus-12-108 | [#531](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/531) | Prevent TalkBack from focusing on hidden/GONE elements |

## Batch 3 ? ChoiceSet Fixes (PRs #532-#534)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 21 | #483 | ? | clean/fix-choiceset-label-repeat-483 | [#532](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/532) | iOS: Stop repeating ChoiceSet label on every radio/checkbox |
| 22 | #180 | ? | clean/fix-choiceset-modal-180 | [#533](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/533) | iOS: Prevent VoiceOver escape to background in dropdown |
| 23 | #89 | ? | clean/fix-choiceset-position-89 | [#534](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/534) | Android: Announce position info for ChoiceSet items |

## Batch 4 ? Input & Image Fixes (PRs #535-#537)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 24 | #107 | ? | clean/fix-email-inputtype-107 | [#535](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/535) | Android: Add TYPE_CLASS_TEXT to email/url/password |
| 25 | #88 | ? | clean/fix-double-announce-88 | [#536](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/536) | Android: Prevent TalkBack double label announcement |
| 26 | #171 | ? | clean/fix-image-selectaction-a11y-171 | [#537](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/537) | iOS: Fallback a11y label for images with selectAction |

## Batch 5 ? Table & ColumnSet Fixes (PRs #538-#540)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 27 | #42/#44 | ? | clean/fix-columnset-reading-order-42 | [#538](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/538) | iOS: Fix VoiceOver reading order for ColumnSet |
| 28 | #48 (iOS) | ? | clean/fix-table-a11y-48-ios | [#539](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/539) | iOS: Set accessibilityContainerType on table |
| 29 | #48 (Android) | ? | clean/fix-table-a11y-48-android | [#540](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/540) | Android: Table heading + CollectionInfo for TalkBack |

## Batch 6 ? Heading, Button & Spinner Fixes (PRs #541-#543)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 30 | #170 | ? | clean/fix-heading-activatable-170 | [#541](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/541) | iOS: Prevent "double tap to activate" on headings |
| 31 | #176 | ? | clean/fix-button-role-twice-176 | [#542](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/542) | iOS: Prevent button role announced twice |
| 32 | #109 | ? | clean/fix-spinner-focus-109 | [#543](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/543) | Android: Improve keyboard focus for Spinner dropdown |

## Batch 7 ? Selected State, Required & Video Fixes (PRs #544-#546)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 33 | #103 | ? | clean/fix-spinner-selected-visual-103 | [#544](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/544) | Android: Highlight selected item in dropdown |
| 34 | #190 | ? | clean/fix-required-asterisk-190 | [#545](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/545) | iOS: Show required asterisk for inputs without label |
| 35 | #168 | ? | clean/fix-video-focus-order-168 | [#546](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/546) | iOS: Improve VoiceOver focus order on video player |

## Batch 8 ? RTL, Container & Picker Fixes (PRs #547-#549)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 36 | #274 | proxy/fix-rtl-config-274 | clean/fix-rtl-config-274 | [#547](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/547) | iOS: Fix duplicate ACRRtlRTL condition in configRtl |
| 37 | #105 | proxy/fix-container-child-a11y-105 | clean/fix-container-child-a11y-105 | [#548](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/548) | Android: Preserve keyboard focusability for container children |
| 38 | #86 | proxy/fix-timepicker-focus-86 | clean/fix-timepicker-focus-86 | [#549](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/549) | Android: Return focus after dismissing time/date picker |

## iOS 26 Toggle Visibility Fix

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 39 | ServiceNow Toggle Bug (TrackingID# 2603110030008961) | proxy/fix-ios26-toggle-double-fire | ? | upstream-pr [#669](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/669) | iOS: Guard against double touchesEnded delivery on iOS 26 |

**Root cause:** iOS 26 Gestures framework re-delivers `touchesEnded:withEvent:` twice per tap.
`ACRContentStackView.touchesEnded` calls `doSelectAction` unconditionally, so `Action.ToggleVisibility`
fires twice ? open then immediately close. Fix adds `_hasFiredActionForCurrentTouch` ivar guard.

**Validated on iOS 26.2 simulator** (Xcode 16.4, macos-15 runner, `com.apple.CoreSimulator.SimRuntime.iOS-26-2`).
Toggle test: initial=54 elements -> expanded=56 -> collapsed=54 (round-trip confirmed).

## Card Speak Property ? Root View Accessibility Label

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 40 | WI#5090802 | proxy/fix-card-speak-accessibility | clean/fix-card-speak-accessibility | upstream-pr [#672](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/672) | iOS+Android: Surface card speak property as accessibilityLabel/contentDescription |

**Problem:** Rendered Adaptive Card root view has hardcoded `ACR Root View` as accessibilityLabel (iOS) and no contentDescription (Android). The card spec's `speak` property is parsed but never surfaced to the rendered view.

**Fix:**
- iOS: Set `ACRView.accessibilityLabel` from card speak property via `GetSpeak()` with full null-safety guards
- Android: Set `contentDescription` from speak; set `accessibilityLiveRegion = POLITE`


## Swift-on-Windows Proxy Drops (vendored kits, proxy-only)

| # | Issue | Proxy Branch | Clean Branch | Upstream PR | Fix |
|---|-------|-------------|-------------|------------|-----|
| 41 | hggzm#49 | proxy/feat-swift-swiftag-bridge | — | pending (proxy-only, no upstream PR planned) | Add `source/ios-swift-swiftag/` -- vendored SwiftAg snapshot (Agent / ConversableAgent / GroupChat patterns / Tool / ToolRegistry, pure Foundation, swift-tools-version:6.0) + runtime symbol-check example `adaptivecards-swiftag-demo` + Windows MSVC gate workflow |
