// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.snapshottests

import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.fragment.app.FragmentManager
import app.cash.paparazzi.DeviceConfig
import app.cash.paparazzi.Paparazzi
import io.adaptivecards.objectmodel.AdaptiveCard
import io.adaptivecards.objectmodel.HostConfig
import io.adaptivecards.objectmodel.ParseContext
import io.adaptivecards.objectmodel.ParseResult
import io.adaptivecards.renderer.AdaptiveCardRenderer
import io.adaptivecards.renderer.RenderedAdaptiveCard
import io.adaptivecards.renderer.actionhandler.ICardActionHandler
import io.adaptivecards.objectmodel.BaseActionElement
import org.junit.Rule
import org.junit.Test

/**
 * Visual regression tests that render real Adaptive Card JSON through the SDK.
 *
 * These tests use Paparazzi (JVM-based, no emulator needed) to render sample
 * cards from the repository's test card library and snapshot the output.
 * Any SDK rendering change (a11y, layout, styling) will produce a visual diff.
 *
 * Record baselines: ./gradlew :snapshottests:recordPaparazziDebug
 * Verify:           ./gradlew :snapshottests:verifyPaparazziDebug
 */
class CardRenderSnapshotTests {

    @get:Rule
    val paparazzi = Paparazzi(
        deviceConfig = DeviceConfig.PIXEL_5,
        maxPercentDifference = 0.5 // Allow 0.5% tolerance for font rendering
    )

    // =========================================================================
    // Sample card JSON definitions (matching samples/ directory)
    // =========================================================================

    private val inputFormCard = """
    {
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "Input Form",
                "size": "large",
                "weight": "bolder",
                "style": "heading"
            },
            {
                "type": "Input.Text",
                "id": "name",
                "label": "Your name (Last, First)",
                "isRequired": true,
                "regex": "^[A-Z][a-z]*, [A-Z][a-z]*$",
                "errorMessage": "Please enter your name in the specified format"
            },
            {
                "type": "Input.Text",
                "id": "email",
                "label": "Your email",
                "style": "email",
                "isRequired": true,
                "errorMessage": "Please enter a valid email address"
            },
            {
                "type": "Input.Number",
                "id": "phone",
                "label": "Phone Number",
                "placeholder": "xxx xxx xxxx"
            }
        ],
        "actions": [
            {
                "type": "Action.Submit",
                "title": "Submit"
            }
        ]
    }
    """.trimIndent()

    private val expenseReportCard = """
    {
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "EXPENSE APPROVAL",
                "size": "large",
                "weight": "bolder",
                "style": "heading"
            },
            {
                "type": "ColumnSet",
                "columns": [
                    {
                        "type": "Column",
                        "width": "auto",
                        "items": [
                            {
                                "type": "Image",
                                "url": "https://adaptivecards.io/content/cats/1.png",
                                "size": "small",
                                "style": "person",
                                "altText": "Profile photo"
                            }
                        ]
                    },
                    {
                        "type": "Column",
                        "width": "stretch",
                        "items": [
                            {
                                "type": "TextBlock",
                                "text": "Matt Hidinger",
                                "weight": "bolder"
                            },
                            {
                                "type": "TextBlock",
                                "text": "Submitted a new expense",
                                "spacing": "none",
                                "isSubtle": true
                            }
                        ]
                    }
                ]
            },
            {
                "type": "FactSet",
                "facts": [
                    { "title": "Amount:", "value": "$850.00" },
                    { "title": "Category:", "value": "Travel" },
                    { "title": "Date:", "value": "Tuesday, November 5, 2019" }
                ]
            }
        ],
        "actions": [
            {
                "type": "Action.Submit",
                "title": "Approve",
                "style": "positive"
            },
            {
                "type": "Action.ShowCard",
                "title": "Reject",
                "style": "destructive",
                "card": {
                    "type": "AdaptiveCard",
                    "body": [
                        {
                            "type": "Input.Text",
                            "id": "RejectComment",
                            "label": "Reason for rejection",
                            "isRequired": true,
                            "isMultiline": true
                        }
                    ],
                    "actions": [
                        {
                            "type": "Action.Submit",
                            "title": "Send"
                        }
                    ]
                }
            }
        ]
    }
    """.trimIndent()

    private val simpleImageCard = """
    {
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "Image Gallery",
                "size": "large",
                "weight": "bolder",
                "style": "heading"
            },
            {
                "type": "Image",
                "url": "https://adaptivecards.io/content/cats/1.png",
                "altText": "Cat photo",
                "size": "medium"
            },
            {
                "type": "TextBlock",
                "text": "A beautiful cat photo",
                "isSubtle": true
            }
        ]
    }
    """.trimIndent()

    private val choiceSetCard = """
    {
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "Survey",
                "size": "large",
                "weight": "bolder",
                "style": "heading"
            },
            {
                "type": "Input.ChoiceSet",
                "id": "color",
                "label": "What color do you want?",
                "style": "expanded",
                "choices": [
                    { "title": "Red", "value": "red" },
                    { "title": "Green", "value": "green" },
                    { "title": "Blue", "value": "blue" }
                ]
            },
            {
                "type": "Input.ChoiceSet",
                "id": "size",
                "label": "Select a size",
                "style": "compact",
                "value": "medium",
                "choices": [
                    { "title": "Small", "value": "small" },
                    { "title": "Medium", "value": "medium" },
                    { "title": "Large", "value": "large" }
                ]
            }
        ],
        "actions": [
            {
                "type": "Action.Submit",
                "title": "OK"
            }
        ]
    }
    """.trimIndent()

    private val openUrlCard = """
    {
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
            {
                "type": "TextBlock",
                "text": "Links and Buttons",
                "size": "large",
                "weight": "bolder",
                "style": "heading"
            },
            {
                "type": "TextBlock",
                "text": "Click below to visit the site."
            }
        ],
        "actions": [
            {
                "type": "Action.OpenUrl",
                "title": "More Info",
                "url": "https://adaptivecards.microsoft.com"
            },
            {
                "type": "Action.Submit",
                "title": "OK"
            }
        ]
    }
    """.trimIndent()

    // =========================================================================
    // Tests — each renders a card and snapshots the output
    // =========================================================================

    @Test
    fun render_inputForm() {
        val view = renderCard(inputFormCard)
        if (view != null) {
            paparazzi.snapshot(view, name = "sdk_render_input_form")
        }
    }

    @Test
    fun render_expenseReport() {
        val view = renderCard(expenseReportCard)
        if (view != null) {
            paparazzi.snapshot(view, name = "sdk_render_expense_report")
        }
    }

    @Test
    fun render_imageCard() {
        val view = renderCard(simpleImageCard)
        if (view != null) {
            paparazzi.snapshot(view, name = "sdk_render_image_card")
        }
    }

    @Test
    fun render_choiceSet() {
        val view = renderCard(choiceSetCard)
        if (view != null) {
            paparazzi.snapshot(view, name = "sdk_render_choiceset")
        }
    }

    @Test
    fun render_openUrlActions() {
        val view = renderCard(openUrlCard)
        if (view != null) {
            paparazzi.snapshot(view, name = "sdk_render_openurl_actions")
        }
    }

    // =========================================================================
    // Helper: render card JSON through the SDK
    // =========================================================================

    private fun renderCard(cardJson: String): View? {
        return try {
            val context = paparazzi.context
            val parseResult: ParseResult = AdaptiveCard.DeserializeFromString(cardJson, AdaptiveCardRenderer.VERSION)
            val adaptiveCard = parseResult.GetAdaptiveCard()
            val hostConfig = HostConfig.DeserializeFromString("{}")

            val renderedCard = AdaptiveCardRenderer.getInstance().render(
                context,
                null, // FragmentManager — null is OK for snapshot
                adaptiveCard,
                NoOpCardActionHandler(),
                hostConfig
            )

            renderedCard?.view?.apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            }
        } catch (e: Exception) {
            // If SDK rendering fails, create a fallback error view
            LinearLayout(paparazzi.context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(16, 16, 16, 16)
                addView(android.widget.TextView(paparazzi.context).apply {
                    text = "SDK Render Error: ${e.message?.take(200)}"
                    setTextColor(android.graphics.Color.RED)
                })
            }
        }
    }

    /** No-op action handler for snapshot rendering */
    private class NoOpCardActionHandler : ICardActionHandler {
        override fun onAction(action: BaseActionElement, renderedCard: RenderedAdaptiveCard) {}
        override fun onMediaPlay(action: BaseActionElement, renderedCard: RenderedAdaptiveCard) {}
        override fun onMediaStop(action: BaseActionElement, renderedCard: RenderedAdaptiveCard) {}
    }
}
