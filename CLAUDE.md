# CLAUDE.md - Teams-AdaptiveCards-Mobile (Fork)

## Repository Setup

- **Upstream:** `microsoft/Teams-AdaptiveCards-Mobile` (GitHub)
- **Fork:** `hggzm/Teams-AdaptiveCards-Mobile` (GitHub)
- **Local remotes:** `origin` = fork, `upstream` = microsoft

## Critical: PR Branch Naming for CI

**Azure Pipelines CI will NOT run on PRs from fork branches.**

When creating PRs against `microsoft/Teams-AdaptiveCards-Mobile`, you MUST:

1. Push the branch directly to the **upstream** repo (not the fork)
2. Use the naming convention: `users/hggzm/<descriptive-name>`
3. Create the PR with `--head users/hggzm/<branch-name>`

### Correct workflow:
```bash
# Work on your branch locally
git checkout -b my-fix main

# ... make changes, commit ...

# Push to UPSTREAM (not origin)
git push upstream my-fix:users/hggzm/my-fix

# Create PR from the upstream branch
gh pr create --repo microsoft/Teams-AdaptiveCards-Mobile \
  --head users/hggzm/my-fix --base main \
  --title "fix: description" --body "..."
```

### Wrong workflow (pipeline will not trigger):
```bash
# DO NOT push to fork and create cross-fork PR
git push origin my-fix
gh pr create --repo microsoft/Teams-AdaptiveCards-Mobile \
  --head hggzm:my-fix --base main  # Pipeline will NOT run!
```

## GitHub Actions (sdk-build-gate.yml)

The fork has a `sdk-build-gate.yml` GitHub Actions workflow at `.github/workflows/sdk-build-gate.yml` for SDK-level code changes. This runs on the fork CI and IS triggered by fork PRs, but it is separate from the upstream Azure Pipelines.

## Build and Test

### iOS
```bash
cd source/ios/AdaptiveCards
pod install --repo-update
xcodebuild test -workspace AdaptiveCards.xcworkspace -scheme AdaptiveCards \
  -sdk iphonesimulator -destination "platform=iOS Simulator,name=iPhone 16"
```

### Android
```bash
cd source/android
./gradlew :adaptivecards:assembleDebug
./gradlew :adaptivecards:testDebugUnitTest
```

## Proxy Workflow

See `docs/PROXY_PR_LOG.md` for the proxy branch workflow documentation.
Development happens on `proxy/fix-*` branches, merged to `proxy/integration`.
Clean branches for upstream PRs branch from `upstream/main`.
