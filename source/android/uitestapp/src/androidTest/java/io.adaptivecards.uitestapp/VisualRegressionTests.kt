// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import androidx.test.espresso.Espresso
import androidx.test.espresso.action.ViewActions
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.rule.GrantPermissionRule
import org.hamcrest.Matchers
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.Timeout
import org.junit.runner.RunWith

/**
 * Visual regression tests -- renders sample cards and captures
 * screenshots for visual comparison.
 *
 * Screenshots saved to /sdcard/screenshots/ (pulled by CI workflow).
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
        .outerRule(GrantPermissionRule.grant(android.Manifest.permission.WRITE_EXTERNAL_STORAGE))
        .around(ActivityScenarioRule<RenderCardUiTestAppActivity>(RenderCardUiTestAppActivity::class.java))
        .around(TestWatchRule())
        .around(Timeout.seconds(120))

    private fun renderCardAndCapture(cardName: String) {
        Espresso.onData(Matchers.`is`(cardName)).perform(ViewActions.click())
        TestHelpers.goToRenderedCardScreen()
        Thread.sleep(2000)
        // Screenshot auto-captured by TestWatchRule on success
    }

    @Test fun visual_ActivityUpdate() = renderCardAndCapture("ActivityUpdate.json")
    @Test fun visual_ExpenseReport() = renderCardAndCapture("ExpenseReport.json")
    @Test fun visual_FlightDetails() = renderCardAndCapture("FlightDetails.json")
    @Test fun visual_FlightUpdate() = renderCardAndCapture("FlightUpdate.json")
    @Test fun visual_InputForm() = renderCardAndCapture("InputForm.json")
    @Test fun visual_Restaurant() = renderCardAndCapture("Restaurant.json")
    @Test fun visual_StockUpdate() = renderCardAndCapture("StockUpdate.json")
    @Test fun visual_WeatherLarge() = renderCardAndCapture("WeatherLarge.json")
    @Test fun visual_SportingEvent() = renderCardAndCapture("SportingEvent.json")

    // Security diagnostic cards for AB#5477531 / AB#5477625 (MT bearer token leak via
    // card backgroundImage). These render the backgroundImage code path so the emulator
    // screenshots confirm the card renders correctly across both fetch modes:
    //  - remote-host backgroundImage (must be fetched WITHOUT the MT bearer token)
    //  - data-URI base64 backgroundImage (decoded in-process, never hits the network)
    @Test fun visual_BackgroundImageRemoteHost() = renderCardAndCapture("BackgroundImageRemoteHostAttack.json")
    @Test fun visual_BackgroundImageDataUri() = renderCardAndCapture("BackgroundImageDataUri.json")
    // Malformed base64 data-URI: the hardened AdaptiveBase64Util::Decode (JNI C++) must reject it
    // and return empty, so the card still renders without a background and the app does not crash.
    @Test fun visual_BackgroundImageMalformedBase64() = renderCardAndCapture("BackgroundImageMalformedBase64.json")
}
// Visual regression test trigger
// API 29 trigger
// screenshot artifact fix trigger
// adb exec-out fix
// screencap approach
// final script fix
// gradlew path fix
// workspace fix
