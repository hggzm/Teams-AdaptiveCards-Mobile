# Proxy Branch Workflow

## Overview

The `proxy/integration` branch on `hggzm/Teams-AdaptiveCards-Mobile` serves as a
**staging area** where changes are validated before being proposed to the upstream
`microsoft/Teams-AdaptiveCards-Mobile` repository.

### Why a Proxy Branch?

1. **Gate validation** - Every push to `proxy/**` triggers the Agent Validation Gate
   (unit tests, visual regression, parity checks) *before* touching upstream.
2. **Safe iteration** - Agents (and humans) can push experimental work, iterate on
   failures, and only propose upstream PRs once the gate is green.
3. **PR tracking** - Changes merged into `proxy/integration` are tracked in
   `docs/PROXY_PR_LOG.md` until they are replicated as PRs on `microsoft/Teams-AdaptiveCards-Mobile`.

---

## Repositories

| Role | Repo | URL |
|------|------|-----|
| **Upstream** (production) | `microsoft/Teams-AdaptiveCards-Mobile` | https://github.com/microsoft/Teams-AdaptiveCards-Mobile |
| **Fork** (our work) | `hggzm/Teams-AdaptiveCards-Mobile` | https://github.com/hggzm/Teams-AdaptiveCards-Mobile |

### Local Remotes

```
origin    git@github.com:hggzm/Teams-AdaptiveCards-Mobile.git   (push to fork)
upstream  https://github.com/microsoft/Teams-AdaptiveCards-Mobile.git  (read-only)
```

---

## Workflow: Making a Change

### Step 1: Create a Feature Branch

```bash
cd ~/code/Teams-AdaptiveCards-Mobile
git checkout proxy/integration
git pull origin proxy/integration
git checkout -b proxy/my-feature
```

### Step 2: Make Changes and Push

```bash
git add -A
git commit -m "feat: describe your change"
git push origin proxy/my-feature
```

### Step 3: Open a PR Against `proxy/integration`

```bash
gh pr create \
  --repo hggzm/Teams-AdaptiveCards-Mobile \
  --base proxy/integration \
  --head proxy/my-feature \
  --title "feat: describe your change"
```

### Step 4: Merge and Log

Once the gate passes, merge the PR and add an entry to `docs/PROXY_PR_LOG.md`.

### Step 5: Replicate to Upstream (Clean Branch Strategy)

**IMPORTANT:** Always use clean branches based on `upstream/main`, not `proxy/integration`.

```bash
git fetch upstream
git checkout -b clean/my-feature upstream/main
git cherry-pick <fix_commit_hash>
git push origin clean/my-feature

# First: Verify on fork
gh pr create --repo hggzm/Teams-AdaptiveCards-Mobile \
  --base main --head clean/my-feature --title "fix: description"

# Then: Open upstream PR
gh pr create --repo microsoft/Teams-AdaptiveCards-Mobile \
  --base main --head hggzm:clean/my-feature --title "fix: description"
```

---

## Clean Branch Strategy

### Why clean branches?

The `proxy/integration` branch contains proxy-only changes:
- CI workflow (`agent-gate.yml`)
- Documentation (`PROXY_*.md`)
- Visual diff testing (`snapshottests/` module, Paparazzi config)

If you branch from `proxy/integration` for an upstream PR, the diff will include
ALL proxy changes (900+ lines across many files).

### How it works

```
upstream/main ──────────────────────── target
       \
        └── clean/fix-my-bug ── cherry-pick only the fix commit
```

Each `clean/fix-*` branch shows exactly **1 file changed** in the PR diff.

### Current clean branches

| Branch | File | Fork PR | Upstream PR |
|--------|------|---------|-------------|
| `clean/fix-image-role-accessibility` | ImageRenderer.java | #30 | #518 |
| `clean/fix-openurl-duplicate-role` | ActionElementRenderer.java | #31 | #519 |
| `clean/fix-error-message-accessibility` | StretchableInputLayout.java | #32 | #520 |
| `clean/fix-dropdown-index-count` | ChoiceSetInputRenderer.java | #33 | #521 |
| `clean/fix-choiceset-group-labels` | ChoiceSetInputRenderer.java | #34 | #522 |
| `clean/fix-showcard-toggle-a11y` | BaseActionElementRenderer.java | #35 | #523 |
| `clean/fix-progress-bar-accessibility` | ProgressBarRenderer.kt | #36 | #524 |

---

## Visual Regression Testing

### Android (Paparazzi Snapshot Tests)

The `snapshottests` module uses [Paparazzi](https://cashapp.github.io/paparazzi/)
for JVM-based screenshot comparison. No emulator required.

#### Commands

```bash
# Record new baselines:
cd source/android
./gradlew :snapshottests:recordPaparazziDebug

# Verify against baselines:
./gradlew :snapshottests:verifyPaparazziDebug
```

#### How it works

1. Paparazzi renders Views using Android's layoutlib on the JVM
2. Screenshots are saved to `snapshottests/src/test/snapshots/` (committed to git)
3. On verify, re-renders and pixel-compares against baselines (0.1% tolerance)
4. Failures produce diff images in `snapshottests/out/failures/`

#### Test coverage

| Test Class | Tests | What it covers |
|-----------|-------|----------------|
| `AccessibilitySnapshotTests` | 14 | Image role, link role, error messages, radio groups, showcard toggle, progress bars |
| `CardLayoutSnapshotTests` | 4 | Activity update, input form, poll results, expense report layouts |

#### CI integration

In `agent-gate.yml`, the `android-visual-tests` job:
- Runs `verifyPaparazziDebug` automatically
- Uploads baselines as `android-paparazzi-baselines` artifact
- Uploads diff images as `android-paparazzi-failures` (on failure only)

#### Re-recording baselines

After intentional visual changes:
```bash
./gradlew :snapshottests:recordPaparazziDebug
git add snapshottests/src/test/snapshots/
git commit -m "chore: update visual baselines"
```

Or via CI manual trigger:
```bash
gh workflow run agent-gate.yml \
  --repo hggzm/Teams-AdaptiveCards-Mobile \
  --ref proxy/integration \
  -f record_baselines=true
```

### iOS (Visualizer Snapshots)

The iOS visual regression job builds ADCIOSVisualizer, runs its tests, and
produces xcresult bundles for analysis.

---

## Agent Validation Gate

**Workflow:** `.github/workflows/agent-gate.yml`

### Jobs

| # | Job | Runner | Blocking |
|---|-----|--------|----------|
| 1a | Structure + JSON Validation | ubuntu | Yes |
| 2a | iOS SPM Build + Test | macOS 15 | Yes |
| 2b | iOS Xcode Build + Unit Tests | macOS 15 | No |
| 2c | Android Build | ubuntu | Yes |
| 2d | Android Unit Tests | ubuntu | No |
| 3a | iOS Visual Regression | macOS 15 | No |
| 3b | Android Visual Regression (Paparazzi) | ubuntu | No |
| 4 | Cross-Platform Parity | ubuntu | No |
| - | **GATE VERDICT** | ubuntu | Aggregator |

### Artifacts

| Artifact | Contents |
|----------|----------|
| `ios-unit-test-logs` | xcodebuild output |
| `ios-visual-test-results` | HTML report + test log |
| `ios-visual-xcresult` | Xcode result bundle |
| `android-unit-test-reports` | JUnit XML + HTML |
| `android-paparazzi-baselines` | Paparazzi PNG baselines |
| `android-paparazzi-failures` | Visual diff images (on failure) |
| `android-visual-test-reports` | JUnit XML from snapshot tests |

---

## Syncing with Upstream

### Keep fork main in sync

```bash
git fetch upstream
git checkout main
git reset --hard upstream/main
git push origin main --force
```

### Merge upstream into proxy/integration

```bash
git fetch upstream
git checkout proxy/integration
git merge upstream/main --no-edit
git push origin proxy/integration
```

---

## Key Paths

| Path | Description |
|------|-------------|
| `.github/workflows/agent-gate.yml` | Agent validation gate |
| `docs/PROXY_BRANCH_WORKFLOW.md` | This document |
| `docs/PROXY_PR_LOG.md` | PR tracking log |
| `docs/PROXY_BRANCH_TRACKER.md` | Branch tracker |
| `source/android/snapshottests/` | Paparazzi visual regression |
| `source/android/adaptivecards/` | Main Android library |
| `source/shared/cpp/ObjectModel/` | Shared C++ model |
