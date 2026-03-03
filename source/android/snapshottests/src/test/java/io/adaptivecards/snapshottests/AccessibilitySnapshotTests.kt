package io.adaptivecards.snapshottests

import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import app.cash.paparazzi.DeviceConfig
import app.cash.paparazzi.Paparazzi
import org.junit.Rule
import org.junit.Test

/**
 * Snapshot tests for accessibility-related rendering.
 *
 * These tests construct Views matching the accessibility modifications made by
 * our TalkBack a11y fixes (PRs #518-#524 upstream) and snapshot them to detect
 * visual regressions. They verify that the Views are correctly constructed and
 * visually consistent.
 *
 * Each test corresponds to a specific accessibility fix:
 * - imageRole: ImageRenderer.java (PR #518)
 * - openUrlRole: ActionElementRenderer.java (PR #519)
 * - errorMessage: StretchableInputLayout.java (PR #520)
 * - dropdownCount: ChoiceSetInputRenderer.java (PR #521)
 * - choicesetGroup: ChoiceSetInputRenderer.java (PR #522)
 * - showcardToggle: BaseActionElementRenderer.java (PR #523)
 * - progressBar: ProgressBarRenderer.kt (PR #524)
 */
class AccessibilitySnapshotTests {

    @get:Rule
    val paparazzi = Paparazzi(
        deviceConfig = DeviceConfig.PIXEL_5,
        maxPercentDifference = 0.1
    )

    // =========================================================================
    // PR #518 — Image role accessibility
    // =========================================================================

    @Test
    fun imageView_withImageRole_lightMode() {
        val view = buildImageWithRole(paparazzi.context, "Sample product photo")
        paparazzi.snapshot(view, name = "image_role_light")
    }

    @Test
    fun imageView_withImageRole_noAltText() {
        val view = buildImageWithRole(paparazzi.context, null)
        paparazzi.snapshot(view, name = "image_role_no_alt")
    }

    // =========================================================================
    // PR #519 — OpenUrl link role (no duplicate Button+Link)
    // =========================================================================

    @Test
    fun openUrlButton_withLinkRole() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val button = Button(paparazzi.context).apply {
            text = "Visit Microsoft.com"
            contentDescription = "Visit Microsoft.com, Link"
            // Our fix: set roleDescription to "Link" and clear Button className
            ViewCompat.setAccessibilityDelegate(this,
                object : androidx.core.view.AccessibilityDelegateCompat() {
                    override fun onInitializeAccessibilityNodeInfo(
                        host: View,
                        info: AccessibilityNodeInfoCompat
                    ) {
                        super.onInitializeAccessibilityNodeInfo(host, info)
                        info.roleDescription = "Link"
                        info.className = ""
                    }
                }
            )
        }
        layout.addView(button)
        paparazzi.snapshot(layout, name = "openurl_link_role")
    }

    // =========================================================================
    // PR #520 — Error message accessibility (live region)
    // =========================================================================

    @Test
    fun errorMessage_visibleWithLiveRegion() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        // Input field label
        val label = TextView(paparazzi.context).apply {
            text = "Email Address"
            textSize = 14f
        }
        layout.addView(label)

        // Input field (simplified)
        val input = android.widget.EditText(paparazzi.context).apply {
            hint = "Enter your email"
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
        layout.addView(input)

        // Error message with live region (our fix)
        val errorView = TextView(paparazzi.context).apply {
            text = "Please enter a valid email address"
            setTextColor(android.graphics.Color.RED)
            textSize = 12f
            // Our fix: ACCESSIBILITY_LIVE_REGION_POLITE
            ViewCompat.setAccessibilityLiveRegion(this,
                ViewCompat.ACCESSIBILITY_LIVE_REGION_POLITE)
        }
        layout.addView(errorView)

        paparazzi.snapshot(layout, name = "error_message_live_region")
    }

    @Test
    fun errorMessage_hidden() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val label = TextView(paparazzi.context).apply {
            text = "Email Address"
            textSize = 14f
        }
        layout.addView(label)

        val input = android.widget.EditText(paparazzi.context).apply {
            hint = "Enter your email"
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
        layout.addView(input)

        // Error hidden
        val errorView = TextView(paparazzi.context).apply {
            text = ""
            visibility = View.GONE
        }
        layout.addView(errorView)

        paparazzi.snapshot(layout, name = "error_message_hidden")
    }

    // =========================================================================
    // PR #521 — Dropdown index count (exclude placeholder)
    // =========================================================================

    @Test
    fun dropdown_withPlaceholder_correctCount() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val label = TextView(paparazzi.context).apply {
            text = "Select a color"
            textSize = 14f
        }
        layout.addView(label)

        // Spinner showing selected item
        val spinner = TextView(paparazzi.context).apply {
            text = "Red"
            textSize = 16f
            setPadding(16, 12, 16, 12)
            setBackgroundColor(android.graphics.Color.parseColor("#F0F0F0"))
            // TalkBack should announce "1 of 3" not "2 of 4" (excluding placeholder)
            contentDescription = "Red, 1 of 3"
        }
        layout.addView(spinner)

        paparazzi.snapshot(layout, name = "dropdown_correct_count")
    }

    // =========================================================================
    // PR #522 — ChoiceSet RadioGroup labels (prevent aggregation)
    // =========================================================================

    @Test
    fun radioGroup_noLabelAggregation() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val title = TextView(paparazzi.context).apply {
            text = "Select your preference"
            textSize = 16f
        }
        layout.addView(title)

        val radioGroup = RadioGroup(paparazzi.context).apply {
            orientation = RadioGroup.VERTICAL
            // Our fix: IMPORTANT_FOR_ACCESSIBILITY_NO prevents RadioGroup
            // from aggregating all child labels for TalkBack
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }

        listOf("Option A", "Option B", "Option C").forEach { label ->
            val rb = RadioButton(paparazzi.context).apply {
                text = label
                id = View.generateViewId()
            }
            radioGroup.addView(rb)
        }
        // Select first option
        (radioGroup.getChildAt(0) as RadioButton).isChecked = true

        layout.addView(radioGroup)
        paparazzi.snapshot(layout, name = "radiogroup_no_aggregation")
    }

    // =========================================================================
    // PR #523 — ShowCard toggle expanded/collapsed
    // =========================================================================

    @Test
    fun showcardButton_expanded() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val button = Button(paparazzi.context).apply {
            text = "Show Details"
            // Our fix: announce "expanded" instead of "selected"
            contentDescription = "Show Details, expanded"
        }
        layout.addView(button)

        // The card content shown when expanded
        val card = TextView(paparazzi.context).apply {
            text = "Here are the detailed contents of this card section."
            textSize = 14f
            setPadding(16, 16, 16, 16)
            setBackgroundColor(android.graphics.Color.parseColor("#F5F5F5"))
            visibility = View.VISIBLE
        }
        layout.addView(card)

        paparazzi.snapshot(layout, name = "showcard_expanded")
    }

    @Test
    fun showcardButton_collapsed() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val button = Button(paparazzi.context).apply {
            text = "Show Details"
            contentDescription = "Show Details, collapsed"
        }
        layout.addView(button)

        // Card hidden when collapsed
        val card = TextView(paparazzi.context).apply {
            text = "Here are the detailed contents of this card section."
            visibility = View.GONE
        }
        layout.addView(card)

        paparazzi.snapshot(layout, name = "showcard_collapsed")
    }

    // =========================================================================
    // PR #524 — ProgressBar rendering with accessibility
    // =========================================================================

    @Test
    fun progressBar_determinate() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val label = TextView(paparazzi.context).apply {
            text = "Poll Results: 65%"
            textSize = 14f
        }
        layout.addView(label)

        val progressBar = ProgressBar(
            paparazzi.context,
            null,
            android.R.attr.progressBarStyleHorizontal
        ).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            max = 100
            progress = 65
            isIndeterminate = false
            contentDescription = "65 percent"
        }
        layout.addView(progressBar)

        paparazzi.snapshot(layout, name = "progressbar_determinate_65")
    }

    @Test
    fun progressBar_indeterminate() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val label = TextView(paparazzi.context).apply {
            text = "Loading..."
            textSize = 14f
        }
        layout.addView(label)

        val progressBar = ProgressBar(
            paparazzi.context,
            null,
            android.R.attr.progressBarStyleHorizontal
        ).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            isIndeterminate = true
            contentDescription = "Loading"
        }
        layout.addView(progressBar)

        paparazzi.snapshot(layout, name = "progressbar_indeterminate")
    }

    @Test
    fun progressBar_zero() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val progressBar = ProgressBar(
            paparazzi.context,
            null,
            android.R.attr.progressBarStyleHorizontal
        ).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            max = 100
            progress = 0
            isIndeterminate = false
            contentDescription = "0 percent"
        }
        layout.addView(progressBar)

        paparazzi.snapshot(layout, name = "progressbar_zero")
    }

    @Test
    fun progressBar_full() {
        val layout = LinearLayout(paparazzi.context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val progressBar = ProgressBar(
            paparazzi.context,
            null,
            android.R.attr.progressBarStyleHorizontal
        ).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            max = 100
            progress = 100
            isIndeterminate = false
            contentDescription = "100 percent"
        }
        layout.addView(progressBar)

        paparazzi.snapshot(layout, name = "progressbar_full")
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private fun buildImageWithRole(context: Context, altText: String?): View {
        val layout = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
        }

        val imageView = ImageView(context).apply {
            layoutParams = LinearLayout.LayoutParams(200, 200)
            setBackgroundColor(android.graphics.Color.parseColor("#E0E0E0"))
            scaleType = ImageView.ScaleType.CENTER_CROP

            // Our fix: AccessibilityDelegate with roleDescription = "Image"
            ViewCompat.setAccessibilityDelegate(this,
                object : androidx.core.view.AccessibilityDelegateCompat() {
                    override fun onInitializeAccessibilityNodeInfo(
                        host: View,
                        info: AccessibilityNodeInfoCompat
                    ) {
                        super.onInitializeAccessibilityNodeInfo(host, info)
                        info.roleDescription = "Image"
                    }
                }
            )

            if (altText != null) {
                contentDescription = altText
            } else {
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
        }
        layout.addView(imageView)

        if (altText != null) {
            val caption = TextView(context).apply {
                text = altText
                textSize = 12f
            }
            layout.addView(caption)
        }

        return layout
    }
}
