# Proxy → Upstream PR Tracking Log

Track every PR merged into `proxy/integration` that needs replication to
`microsoft/Teams-AdaptiveCards-Mobile` main.

## Status Legend

| Status | Meaning |
|--------|---------|
| `pending` | Merged to proxy; not yet proposed upstream |
| `upstream-pr` | PR opened against upstream |
| `merged` | Upstream PR merged |
| `skipped` | Proxy-only (CI config, docs) — no upstream PR needed |

## Tracking Table

| # | Proxy PR | Date | Title | Commit | Status | Fork PR (clean) | Upstream PR |
|---|----------|------|-------|--------|--------|-----------------|-------------|
| 1 | — | 2025-01-18 | ci: add agent validation gate | `04ff142d` | skipped | — | CI-only, not applicable to upstream |
| 2 | — | 2025-01-18 | ci: skip invalid test JSON files | `b4c4ef0b` | skipped | — | CI-only |
| 3 | — | 2025-01-18 | docs: add proxy branch tracker | `6117dc06` | skipped | — | Docs-only |
| 4 | — | 2025-01-18 | ci: upgrade gate with visual regression | `3eb25eee` | skipped | — | CI-only |
| 5 | — | 2026-03-01 | docs: add proxy workflow guide + PR log | `d798b829` | skipped | — | Docs-only |
| 6 | #14 | 2026-03-01 | docs: add descriptive comment to SharedAdaptiveCard.cpp | `7bd23944` | upstream-pr | — | [#508](https://github.com/microsoft/Teams-AdaptiveCards-Mobile/pull/508) |
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
| <next_#> | #<pr_number> | YYYY-MM-DD | <title> | `<short_hash>` | pending | — | — |
```

When a clean fork PR is created:

```markdown
| <#> | ... | ... | ... | ... | pending | [#NN](url) | — |
```

When the upstream PR is created:

```markdown
| <#> | ... | ... | ... | ... | upstream-pr | [#NN](url) | [#NNN](url) |
```

When merged upstream:

```markdown
| <#> | ... | ... | ... | ... | merged | [#NN](url) | [#NNN](url) |
```
