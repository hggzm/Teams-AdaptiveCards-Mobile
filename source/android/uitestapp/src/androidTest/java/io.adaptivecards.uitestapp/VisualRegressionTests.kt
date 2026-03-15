// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import androidx.test.espresso.Espresso
import androidx.test.espresso.action.ViewActions
import androidx.test.espresso.matcher.ViewMatchers
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import org.hamcrest.Matchers
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.Timeout
import org.junit.runner.RunWith

/**
 * Visual regression tests — renders multiple sample cards and captures
 * screenshots for comparison. Each test loads a card from the test assets,
 * renders it, and takes a named screenshot.
 *
 * Screenshots are saved to /sdcard/screenshots/ on the emulator.
 * The CI workflow pulls them and uploads as artifacts for visual diff.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class VisualRegressionTests {
    companion object {
        init {
            System.loadLibrary("adaptivecards-native-lib")
        }
    }

    @get:Rule
    val testRule: RuleChain = RuleChain
        .outerRule(ActivityScenarioRule<RenderCardUiTestAppActivity>(RenderCardUiTestAppActivity::class.java))
        .around(Timeout.seconds(120))

    private val screenshotHelper = ScreenshotHelper("visual_regression")

    private fun renderCardAndCapture(cardName: String, screenshotName: String) {
        // Select the card from the list
        Espresso.onData(Matchers.`is`(cardName)).perform(ViewActions.click())
        // Navigate to the rendered card screen
        TestHelpers.goToRenderedCardScreen()
        // Wait for rendering to settle
        Thread.sleep(1000)
        // Capture screenshot
        ScreenshotHelper(screenshotName).takeScreenshot()
        // Go back to card list for next test
        Espresso.pressBack()
        Espresso.pressBack()
    }

    // =========================================================================
    // Scenario Cards (v1.5) — common real-world card patterns
    // =========================================================================

    @Test
    fun visual_ActivityUpdate() {
        renderCardAndCapture("ActivityUpdate.json", "card_ActivityUpdate")
    }

    @Test
    fun visual_ExpenseReport() {
        renderCardAndCapture("ExpenseReport.json", "card_ExpenseReport")
    }

    @Test
    fun visual_FlightDetails() {
        renderCardAndCapture("FlightDetails.json", "card_FlightDetails")
    }

    @Test
    fun visual_FlightUpdate() {
        renderCardAndCapture("FlightUpdate.json", "card_FlightUpdate")
    }

    @Test
    fun visual_InputForm() {
        renderCardAndCapture("InputForm.json", "card_InputForm")
    }

    @Test
    fun visual_Restaurant() {
        renderCardAndCapture("Restaurant.json", "card_Restaurant")
    }

    @Test
    fun visual_StockUpdate() {
        renderCardAndCapture("StockUpdate.json", "card_StockUpdate")
    }

    @Test
    fun visual_WeatherLarge() {
        renderCardAndCapture("WeatherLarge.json", "card_WeatherLarge")
    }

    @Test
    fun visual_SportingEvent() {
        renderCardAndCapture("SportingEvent.json", "card_SportingEvent")
    }
}
// Visual regression test trigger
