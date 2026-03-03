# Card-Content Issues Analysis

These issues were triaged across 8 batches of accessibility work. They are
**not renderer bugs** — the renderer faithfully displays what the card JSON
provides. The fix requires changes to the **card JSON content** (by the card
author), not the SDK renderer code.

## Summary

| Issue | Platform | Root Cause | Recommended Action |
|-------|----------|-----------|-------------------|
| #39 | iOS | Currency "$4,032.54" read digit-by-digit by VoiceOver | Card author: use `accessibilityText` or format as "4032.54 USD" |
| #40 | iOS | Abbreviated day "Tue" not expanded to "Tuesday" | Card author: use full day names in card JSON |
| #92 | Android | "Flight to JFK" not marked as heading | Card author: set `style: "heading"` on the TextBlock |
| #94 | Android | "SFO"/"JFK" announced without context | Card author: add descriptive labels or `accessibilityText` |
| #101 | Android | "Tue, Nov 5 2019" not expanded to full weekday | Card author: use full day names in card JSON |
| #102 | Android | Stock arrow (↑) not described by TalkBack | Card author: add `accessibilityText` describing the trend direction |
| #179 | iOS | "Sat" not expanded to "Saturday" | Card author: use full day names in card JSON |

## Detailed Analysis

### #39 — Currency formatting read incorrectly by VoiceOver

**Issue:** VoiceOver reads "$4,032.54" as "Dollar sign four comma thirty-two
period fifty-four" instead of "four thousand thirty-two dollars and fifty-four
cents."

**Analysis:** The card JSON contains the text "$4,032.54" as a plain string in
a TextBlock. VoiceOver's text-to-speech engine interprets the comma as a list
separator rather than a thousands separator. This is a known iOS VoiceOver
behavior with formatted currency strings.

**Why not a renderer fix:** The renderer correctly displays the text from the
card JSON. The SDK has no knowledge of whether a string represents currency,
a list, or other data. Adding currency-detection heuristics to the renderer
would be fragile and incorrect for non-currency uses of commas.

**Recommendation for card authors:**
- Use `accessibilityText` property on the TextBlock to provide a screen-reader-friendly version: `"accessibilityText": "$4,032.54"`
- Or format the amount without commas: `"4032.54 USD"`
- Or use a separate hidden TextBlock with the spoken form

---

### #40 & #179 & #101 — Abbreviated day names not expanded

**Issues:**
- #40: "Tue, May 30, 2017" → VoiceOver says "Tue" not "Tuesday"
- #179: "Sat, August 31, 2019" → VoiceOver says "Sat" not "Saturday"
- #101: "Tue, Nov 5 2019" → TalkBack says "Tue" not "Tuesday"

**Analysis:** The card JSON contains abbreviated day names ("Tue", "Sat") as
plain text in TextBlock elements. Screen readers read the text verbatim — they
don't attempt to expand abbreviations since "Tue" could be a name, an
abbreviation, or an acronym.

**Why not a renderer fix:** The renderer displays the exact text from the JSON.
Adding abbreviation-expansion logic would be:
1. Language-dependent (different abbreviations in different locales)
2. Ambiguous ("Sat" could mean "Saturday" or "SAT test" or "satellite")
3. A card-authoring concern, not a rendering concern

**Recommendation for card authors:**
- Use full day names: `"Tuesday, May 30, 2017"`
- Or use `accessibilityText` to provide the expanded form
- Or use `{{DATE()}}` template functions if available for locale-aware formatting

---

### #92 — TextBlock not defined as heading

**Issue:** "Flight to JFK" is not announced as a heading by TalkBack, and
heading navigation (rotor) doesn't find it.

**Analysis:** The card JSON does not set `style: "heading"` on this TextBlock.
The renderer correctly applies `UIAccessibilityTraitHeader` (iOS) and
`info.setHeading(true)` (Android) when `TextStyle.Heading` is set. Without
that style, the TextBlock renders as plain text.

**Why not a renderer fix:** The renderer already supports heading semantics —
it's the card JSON that doesn't use them. The renderer cannot guess which
TextBlocks should be headings based on content alone ("Flight to JFK" could
be a heading, a label, or a description).

**Recommendation for card authors:**
- Add `"style": "heading"` to the TextBlock in the card JSON
- This will cause the renderer to apply heading semantics on both platforms

---

### #94 — Airport codes lack context

**Issue:** TalkBack announces "SFO" and "JFK" without explaining they are
airport codes or what they represent (departure/arrival).

**Analysis:** The card JSON contains TextBlocks with just "SFO" and "JFK" as
plain text. There are no labels, tooltips, or accessibility descriptions to
provide context. The renderer correctly displays and announces the text content.

**Why not a renderer fix:** The renderer has no way to know that "SFO" is an
airport code, that it represents a departure city, or that it should be
expanded to "San Francisco International Airport." This is domain-specific
knowledge that belongs in the card content.

**Recommendation for card authors:**
- Add `accessibilityText`: `"accessibilityText": "Departing from San Francisco International Airport (SFO)"`
- Or add a descriptive label TextBlock below: `"From: SFO"`
- Or use `tooltip` property for additional context

---

### #102 — Stock trend arrow not described

**Issue:** TalkBack announces "2.69 USD 2.13%" without mentioning that stocks
are rising (the arrow ↑ icon is not described).

**Analysis:** The card JSON uses an Image element for the arrow icon without
alt text. The percentage change is a plain TextBlock without context about
direction. The renderer correctly displays both elements but has no way to
infer "stocks are rising" from an image and a number.

**Why not a renderer fix:** The renderer already supports `altText` on Image
elements. The card JSON doesn't provide it. Adding stock-market-specific logic
("if there's a green arrow and a percentage, say 'stocks are rising'") would
be domain-specific heuristics that don't belong in a generic card renderer.

**Recommendation for card authors:**
- Add `altText` to the arrow Image: `"altText": "Stocks rising"`
- Or add `accessibilityText` to the TextBlock: `"accessibilityText": "Increase of 2.13%"`
- Or use a hidden TextBlock with the complete description

---

## Impact on Renderer Work

All renderer-fixable accessibility issues have been addressed in PRs #518-#549
(38 fixes across 8 batches). These 7 remaining issues require card-author
action and should be communicated:

1. To card authors via documentation updates
2. To the test team via issue comments explaining the root cause
3. Optionally, as SDK documentation improvements showing best practices
   for accessible card authoring
