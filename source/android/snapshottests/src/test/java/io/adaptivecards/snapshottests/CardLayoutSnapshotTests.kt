package io.adaptivecards.snapshottests

import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import app.cash.paparazzi.DeviceConfig
import app.cash.paparazzi.Paparazzi
import org.junit.Rule
import org.junit.Test

/**
 * Snapshot tests for common Adaptive Card layouts.
 *
 * These tests verify the visual appearance of card-like layouts combining
 * multiple components — similar to how real Adaptive Cards appear in Teams.
 * Each layout mimics a common card pattern from the test card library.
 */
class CardLayoutSnapshotTests {

    @get:Rule
    val paparazzi = Paparazzi(
        deviceConfig = DeviceConfig.PIXEL_5,
        maxPercentDifference = 0.1
    )

    @Test
    fun activityUpdate_cardLayout() {
        val card = buildActivityUpdateCard(paparazzi.context)
        paparazzi.snapshot(card, name = "card_activity_update")
    }

    @Test
    fun inputForm_cardLayout() {
        val card = buildInputFormCard(paparazzi.context)
        paparazzi.snapshot(card, name = "card_input_form")
    }

    @Test
    fun pollResults_cardLayout() {
        val card = buildPollResultsCard(paparazzi.context)
        paparazzi.snapshot(card, name = "card_poll_results")
    }

    @Test
    fun expenseReport_cardLayout() {
        val card = buildExpenseReportCard(paparazzi.context)
        paparazzi.snapshot(card, name = "card_expense_report")
    }

    // =========================================================================
    // Card builders
    // =========================================================================

    private fun buildActivityUpdateCard(context: android.content.Context): View {
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
            setBackgroundColor(android.graphics.Color.WHITE)

            // Header row with image + text
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(ImageView(context).apply {
                    layoutParams = LinearLayout.LayoutParams(80, 80).apply {
                        rightMargin = 16
                    }
                    setBackgroundColor(android.graphics.Color.parseColor("#0078D4"))
                    contentDescription = "Profile photo"
                    // PR #518 fix: Image role
                    androidx.core.view.ViewCompat.setAccessibilityDelegate(this,
                        object : androidx.core.view.AccessibilityDelegateCompat() {
                            override fun onInitializeAccessibilityNodeInfo(
                                host: View,
                                info: androidx.core.view.accessibility.AccessibilityNodeInfoCompat
                            ) {
                                super.onInitializeAccessibilityNodeInfo(host, info)
                                info.roleDescription = "Image"
                            }
                        })
                })
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(TextView(context).apply {
                        text = "Matt Hidinger"
                        textSize = 18f
                        setTypeface(null, android.graphics.Typeface.BOLD)
                    })
                    addView(TextView(context).apply {
                        text = "Created a new task"
                        textSize = 14f
                    })
                })
            })

            // Body
            addView(TextView(context).apply {
                text = "Review the Adaptive Cards documentation and provide feedback."
                textSize = 14f
                setPadding(0, 16, 0, 16)
            })

            // Action buttons
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(Button(context).apply {
                    text = "View Task"
                })
                addView(Button(context).apply {
                    text = "More Info"
                    contentDescription = "More Info, Link"
                    // PR #519 fix: Link role
                    androidx.core.view.ViewCompat.setAccessibilityDelegate(this,
                        object : androidx.core.view.AccessibilityDelegateCompat() {
                            override fun onInitializeAccessibilityNodeInfo(
                                host: View,
                                info: androidx.core.view.accessibility.AccessibilityNodeInfoCompat
                            ) {
                                super.onInitializeAccessibilityNodeInfo(host, info)
                                info.roleDescription = "Link"
                                info.className = ""
                            }
                        })
                })
            })
        }
    }

    private fun buildInputFormCard(context: android.content.Context): View {
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
            setBackgroundColor(android.graphics.Color.WHITE)

            addView(TextView(context).apply {
                text = "Input Form"
                textSize = 20f
                setTypeface(null, android.graphics.Typeface.BOLD)
            })

            // Name input with error (PR #520)
            addView(TextView(context).apply {
                text = "Name *"
                textSize = 14f
                setPadding(0, 16, 0, 4)
            })
            addView(android.widget.EditText(context).apply {
                hint = "Enter your name"
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            })
            addView(TextView(context).apply {
                text = "Name is required"
                setTextColor(android.graphics.Color.RED)
                textSize = 12f
                // PR #520 fix: live region
                androidx.core.view.ViewCompat.setAccessibilityLiveRegion(this,
                    androidx.core.view.ViewCompat.ACCESSIBILITY_LIVE_REGION_POLITE)
            })

            // Radio choices (PR #522)
            addView(TextView(context).apply {
                text = "Preference"
                textSize = 14f
                setPadding(0, 16, 0, 4)
            })
            addView(RadioGroup(context).apply {
                orientation = RadioGroup.VERTICAL
                // PR #522 fix: prevent aggregation
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                listOf("Email", "Phone", "Text").forEach { label ->
                    addView(RadioButton(context).apply {
                        text = label
                        id = View.generateViewId()
                    })
                }
            })

            addView(Button(context).apply {
                text = "Submit"
                setPadding(0, 16, 0, 0)
            })
        }
    }

    private fun buildPollResultsCard(context: android.content.Context): View {
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
            setBackgroundColor(android.graphics.Color.WHITE)

            addView(TextView(context).apply {
                text = "Poll: Favorite Language?"
                textSize = 18f
                setTypeface(null, android.graphics.Typeface.BOLD)
            })

            // Progress bars (PR #524)
            data class PollOption(val label: String, val percent: Int)
            val options = listOf(
                PollOption("Kotlin", 45),
                PollOption("Swift", 30),
                PollOption("TypeScript", 20),
                PollOption("Other", 5)
            )

            options.forEach { option ->
                addView(TextView(context).apply {
                    text = "${option.label}: ${option.percent}%"
                    textSize = 14f
                    setPadding(0, 12, 0, 4)
                })
                addView(ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
                    layoutParams = LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT
                    )
                    max = 100
                    progress = option.percent
                    isIndeterminate = false
                    contentDescription = "${option.percent} percent"
                })
            }
        }
    }

    private fun buildExpenseReportCard(context: android.content.Context): View {
        return LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setPadding(24, 24, 24, 24)
            setBackgroundColor(android.graphics.Color.WHITE)

            addView(TextView(context).apply {
                text = "Expense Report"
                textSize = 20f
                setTypeface(null, android.graphics.Typeface.BOLD)
            })

            addView(TextView(context).apply {
                text = "Total: $400.00"
                textSize = 16f
                setPadding(0, 8, 0, 16)
            })

            // ShowCard toggle (PR #523)
            addView(Button(context).apply {
                text = "Show History"
                contentDescription = "Show History, expanded"
            })

            // History section (visible when expanded)
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(android.graphics.Color.parseColor("#F5F5F5"))
                setPadding(16, 16, 16, 16)
                addView(TextView(context).apply {
                    text = "Mar 1 — Office Supplies: \$50.00"
                    textSize = 12f
                })
                addView(TextView(context).apply {
                    text = "Feb 28 — Travel: \$200.00"
                    textSize = 12f
                })
                addView(TextView(context).apply {
                    text = "Feb 27 — Meals: \$150.00"
                    textSize = 12f
                })
            })
        }
    }
}
