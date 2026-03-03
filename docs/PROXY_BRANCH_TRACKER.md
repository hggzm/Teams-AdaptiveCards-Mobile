# Proxy Branch Tracker

## Branch: `proxy/integration`

**Purpose:** Agent validation gate for the production AdaptiveCards-Mobile SDK.

**Fork:** `hggzm/Teams-AdaptiveCards-Mobile` (fork of `microsoft/Teams-AdaptiveCards-Mobile`)
**Created from:** `upstream/main` at commit `2db8482b` (Merge PR #503 - v3.8.1)

---

## Gate Status

| Run | Conclusion | Commit | Date |
|-----|-----------|--------|------|
| [#22547502002](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/actions/runs/22547502002) | **SUCCESS** | `b4c4ef0b` | 2025-03-01 |

## Gate Architecture

The `agent-gate.yml` workflow runs **8 parallel jobs** + a **gate verdict** aggregator:

### Blocking Jobs (must pass)
1. **structure-check** - Validates repo structure, shared C++ headers, test card JSON syntax
2. **ios-spm-build** - `swift build` + `swift test --filter AdaptiveCardsTest` on macOS 15
3. **android-build** - `./gradlew :adaptivecards:assembleDebug` with JDK 17 on Ubuntu

### Advisory Jobs (continue-on-error)
4. **ios-xcodebuild** - CocoaPods install + xcodebuild workspace build on macOS 15
5. **android-unit-tests** - `./gradlew :adaptivecards:testDebugUnitTest`, uploads test reports
6. **ios-visual-tests** - iOS Visualizer card rendering + xcresult bundles
7. **android-visual-tests** - **Paparazzi snapshot testing** (pixel-diff visual regression)
8. **parity-check** - Source inventory counts across C++, iOS, Android

### Gate Verdict
- Requires: structure-check + ios-spm-build + android-build
- Reports advisory job status but does not block on them

## Visual Regression Testing

### Android (Paparazzi)
- **Module:** `source/android/snapshottests`
- **Plugin:** [Paparazzi 1.3.4](https://cashapp.github.io/paparazzi/) (JVM-based, no emulator needed)
- **Record baselines:** `./gradlew :snapshottests:recordPaparazziDebug`
- **Verify snapshots:** `./gradlew :snapshottests:verifyPaparazziDebug`
- **Baselines stored:** `source/android/snapshottests/src/test/snapshots/`

| Test Class | Tests | Coverage |
|-----------|-------|----------|
| `AccessibilitySnapshotTests` | 14 | Image role, link role, error messages, radio groups, showcard toggle, progress bars |
| `CardLayoutSnapshotTests` | 4 | Activity update, input form, poll results, expense report card layouts |

### iOS (Custom Snapshot Framework)
- **Module:** `source/ios/SnapshotTests`
- **Framework:** Custom `SnapshotTestCase` (ported from AdaptiveCards-Mobile, zero external deps)
- **Record baselines:** `RECORD_SNAPSHOTS=1 xcodebuild test -scheme AdaptiveCards-Package ...`
- **Verify snapshots:** `xcodebuild test -scheme AdaptiveCards-Package -only-testing:VisualSnapshotTests ...`
- **Baselines stored:** `source/ios/SnapshotTests/Snapshots/Baselines/`
- **Diff images:** `source/ios/SnapshotTests/Snapshots/Diffs/` (red-highlighted pixel diffs)
- Also runs ADCIOSVisualizer tests via xcodebuild (xcresult bundles)

| Test Class | Tests | Coverage |
|-----------|-------|----------|
| `AccessibilitySnapshotTests` | 14 | Image role, link role, error messages, radio groups, showcard toggle, progress bars |
| `CardLayoutSnapshotTests` | 4 | Activity update, input form, poll results, showcard interaction layouts |

## Accessibility Fix PRs

All 8 fork accessibility issues (#15-#22) have been addressed and closed.

| Fork Issue | Upstream Issue | Fix | Fork PR | Upstream PR | Status |
|------------|----------------|-----|---------|------------|--------|
| #17 | [#490](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/490) | Image role on ImageView | [#30](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/30) | [#518](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/518) | open |
| #21 | [#375](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/375) | Image role (Activity Card) | [#30](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/30) | [#518](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/518) | open |
| #16 | [#492](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/492) | OpenUrl duplicate role | [#31](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/31) | [#519](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/519) | open |
| #15 | [#493](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/493) | Error message a11y | [#32](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/32) | [#520](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/520) | open |
| #19 | [#466](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/466) | Dropdown index count | [#33](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/33) | [#521](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/521) | open |
| #18 | [#483](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/483) | RadioGroup labels | [#34](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/34) | [#522](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/522) | open |
| #22 | [#374](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/374) | ShowCard toggle | [#35](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/35) | [#523](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/523) | open |
| #20 | [#451](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/issues/451) | ProgressBar a11y | [#36](https://github.com/hggzm/Teams-AdaptiveCards-Mobile/pull/36) | [#524](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/524) | open |

## Build Systems

### iOS
- **SPM** (`Package.swift`): ObjectModel (C++17) + AdaptiveCards (ObjC/Swift) + AdaptiveCardsTest. iOS 13+.
- **Xcode** (`AdaptiveCards.xcworkspace`): CocoaPods (FluentUI 0.1.9, SVGKit 3.0.0). iOS 15+.

### Android
- **Gradle 8.10**, AGP 8.5.2, Kotlin 1.9.24, JDK 17, NDK 28.0.13004108
- CMake builds `adaptivecards-native-lib` from `source/shared/cpp/ObjectModel/*.cpp`
- **Modules:** `adaptivecards`, `snapshottests` (Paparazzi), `uitestapp`, `mobile`, `mobilechatapp`

### iOS (SPM)
- **Package.swift:** ObjectModel (C++17) + AdaptiveCards (ObjC/Swift) + AdaptiveCardsTest + **VisualSnapshotTests**

## Dashboard Tracking

| Job ID | Executor | Interval |
|--------|----------|----------|
| `github-issues-sync-prod-fork` | `github-issues-sync` | 600s |
| `github-work-state-tracker-prod-fork` | `github-work-state-tracker` | 300s |

## Remotes

```
origin    git@github.com:hggzm/Teams-AdaptiveCards-Mobile.git
upstream  https://github.com/microsoft/Teams-AdaptiveCards-Mobile.git
```

## Key Paths

| Path | Description |
|------|-------------|
| `.github/workflows/agent-gate.yml` | Agent validation gate workflow |
| `source/android/snapshottests/` | Paparazzi snapshot test module |
| `source/ios/SnapshotTests/` | iOS snapshot test module (custom framework) |
| `source/android/adaptivecards/` | Main Android library |
| `source/shared/cpp/ObjectModel/` | Shared C++ object model |
| `source/ios/AdaptiveCards/` | iOS workspace |
