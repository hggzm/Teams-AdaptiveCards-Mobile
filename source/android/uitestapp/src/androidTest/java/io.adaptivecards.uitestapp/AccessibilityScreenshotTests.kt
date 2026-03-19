// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.os.ParcelFileDescriptor
import android.view.View
import androidx.test.espresso.Espresso
import androidx.test.espresso.UiController
import androidx.test.espresso.ViewAction
import androidx.test.espresso.action.ViewActions
import androidx.test.espresso.assertion.ViewAssertions
import androidx.test.espresso.matcher.ViewMatchers
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import org.hamcrest.Matcher
import org.hamcrest.Matchers
import org.junit.Assert
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.Timeout
import org.junit.runner.RunWith
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Accessibility screenshot tests -- renders Adaptive Cards on an emulator,
 * interacts with accessibility-relevant elements, and captures named
 * screenshots WHILE the card is displayed on screen.
 *
 * Key: screenshots are taken from INSIDE the test via executeShellCommand
 * ("screencap -p /data/local/tmp/...") so the card is guaranteed to be
 * visible. Post-test screencaps from the workflow would only show the
 * home screen since the activity is destroyed when the test finishes.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class AccessibilityScreenshotTests {

    companion object {
        init {
            System.loadLibrary("adaptivecards-native-lib")
        }
        private const val SCREENSHOT_DIR = "/data/local/tmp/a11y_screenshots"
        private const val A11Y_TREE_DIR = "/data/local/tmp/a11y_trees"
    }

    @get:Rule
    val testRule: RuleChain = RuleChain
        .outerRule(GrantPermissionRule.grant(android.Manifest.permission.WRITE_EXTERNAL_STORAGE))
        .around(ActivityScenarioRule<RenderCardUiTestAppActivity>(
            RenderCardUiTestAppActivity::class.java))
        .around(Timeout.seconds(120))

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    private fun renderCard(cardName: String) {
        Espresso.onData(Matchers.`is`(cardName)).perform(ViewActions.click())
        TestHelpers.goToRenderedCardScreen()
        Thread.sleep(3000) // wait for card render + image loads
    }

    /**
     * Take a screenshot WHILE the card is displayed by executing
     * screencap from within the running test process.
     * Saves to /data/local/tmp/ which is pullable via adb without run-as.
     */
    private fun takeNamedScreenshot(name: String) {
        Thread.sleep(500) // let UI settle

        val instrumentation = InstrumentationRegistry.getInstrumentation()

        // Ensure output directories exist
        execShellBlocking("mkdir -p $SCREENSHOT_DIR")

        // Take screencap while the card is still on screen
        val path = "$SCREENSHOT_DIR/android_a11y_$name.png"
        execShellBlocking("screencap -p $path")

        // Dump the accessibility/view hierarchy via UiDevice
        // Write to app's filesDir (app user can always write there).
        // Workflow pulls via: adb exec-out run-as PKG cat files/a11y_trees/...
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        try {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val treeDir = java.io.File(context.filesDir, "a11y_trees")
            treeDir.mkdirs()
            val treeFile = java.io.File(treeDir, "android_a11y_$name.xml")
            device.dumpWindowHierarchy(treeFile)
            println("A11y tree: ${treeFile.absolutePath} (${treeFile.length()} bytes)")
        } catch (e: Exception) {
            println("A11y tree dump failed: ${e.message}")
        }

        // Log for CI pipeline to find
        execShellBlocking("log -t A11Y_SCREENSHOT $name")

        // Verify the screenshot was written
        val imgSize = execShellBlocking("stat -c%s $path 2>/dev/null || echo 0")
        println("Screenshot: $path ($imgSize bytes)")
    }

    /**
     * Execute a shell command via UiAutomation and wait for it to finish.
     */
    private fun execShellBlocking(cmd: String): String {
        val pfd = InstrumentationRegistry.getInstrumentation()
            .uiAutomation.executeShellCommand(cmd)
        return BufferedReader(
            InputStreamReader(ParcelFileDescriptor.AutoCloseInputStream(pfd))
        ).use { it.readText().trim() }
    }

    private fun assertSelected(expected: Boolean): ViewAction {
        return object : ViewAction {
            override fun getConstraints(): Matcher<View> =
                ViewMatchers.isAssignableFrom(View::class.java)
            override fun getDescription(): String =
                "assert view selected=$expected"
            override fun perform(uiController: UiController, view: View) {
                Assert.assertEquals(
                    "View selected state should be $expected",
                    expected, view.isSelected
                )
            }
        }
    }

    private fun visibleTextContaining(text: String): Matcher<View> {
        return Matchers.allOf(
            ViewMatchers.withText(Matchers.containsString(text)),
            ViewMatchers.withEffectiveVisibility(ViewMatchers.Visibility.VISIBLE)
        )
    }

    // ---------------------------------------------------------------
    // Scenario 1: ShowCard expand/collapse (PR #663) -- ExpenseReport
    // ---------------------------------------------------------------

    @Test
    fun a11y_showcard_collapsed() {
        renderCard("ExpenseReport.json")
        Espresso.onView(ViewMatchers.withText("Reject"))
            .check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        takeNamedScreenshot("showcard_collapsed")
    }

    @Test
    fun a11y_showcard_expanded() {
        renderCard("ExpenseReport.json")
        Espresso.onView(ViewMatchers.withText("Reject"))
            .perform(ViewActions.scrollTo(), ViewActions.click())
        Thread.sleep(1000)
        Espresso.onView(ViewMatchers.withText("Reject"))
            .perform(assertSelected(true))
        Espresso.onView(visibleTextContaining("appropriate reason for rejection"))
            .check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        takeNamedScreenshot("showcard_expanded")
    }

    @Test
    fun a11y_showcard_collapsed_again() {
        renderCard("ExpenseReport.json")
        Espresso.onView(ViewMatchers.withText("Reject"))
            .perform(ViewActions.scrollTo(), ViewActions.click())
        Thread.sleep(500)
        Espresso.onView(ViewMatchers.withText("Reject"))
            .perform(ViewActions.click())
        Thread.sleep(500)
        Espresso.onView(ViewMatchers.withText("Reject"))
            .perform(assertSelected(false))
        takeNamedScreenshot("showcard_collapsed_again")
    }

    // ---------------------------------------------------------------
    // Scenario 2: Validation error announcement (PR #662) -- InputForm
    // ---------------------------------------------------------------

    @Test
    fun a11y_validation_empty_form() {
        renderCard("InputForm.json")
        takeNamedScreenshot("validation_empty_form")
    }

    @Test
    fun a11y_validation_error_visible() {
        renderCard("InputForm.json")
        Espresso.onView(ViewMatchers.withText("Submit"))
            .perform(ViewActions.scrollTo(), ViewActions.click())
        Thread.sleep(1000)
        Espresso.onView(visibleTextContaining("Please enter your name"))
            .check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        takeNamedScreenshot("validation_error_visible")
    }

    // ---------------------------------------------------------------
    // Scenario 3: ToggleVisibility -- ExpenseReport "Show history"
    // ---------------------------------------------------------------

    @Test
    fun a11y_toggle_visibility_hidden() {
        renderCard("ExpenseReport.json")
        Espresso.onView(ViewMatchers.withText("Show history"))
            .perform(ViewActions.scrollTo())
            .check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        takeNamedScreenshot("toggle_visibility_hidden")
    }

    @Test
    fun a11y_toggle_visibility_revealed() {
        renderCard("ExpenseReport.json")
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        Espresso.onView(ViewMatchers.withText("Show history"))
            .perform(ViewActions.scrollTo())
        Thread.sleep(500)
        val showHistory = device.findObject(By.text("Show history"))
        Assert.assertNotNull("Show history text should be on screen", showHistory)
        showHistory.click()
        Thread.sleep(2000)
        takeNamedScreenshot("toggle_visibility_revealed")
    }

    // ---------------------------------------------------------------
    // Scenario 4: ActivityUpdate ShowCard
    // ---------------------------------------------------------------

    @Test
    fun a11y_activity_showcard_buttons() {
        renderCard("ActivityUpdate.json")
        Espresso.onView(ViewMatchers.withText("Set due date"))
            .check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        Espresso.onView(ViewMatchers.withText("Comment"))
            .check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        takeNamedScreenshot("activity_showcard_buttons")
    }

    @Test
    fun a11y_activity_showcard_expanded() {
        renderCard("ActivityUpdate.json")
        Espresso.onView(ViewMatchers.withText("Comment"))
            .perform(ViewActions.click())
        Thread.sleep(1000)
        Espresso.onView(ViewMatchers.withText("Comment"))
            .perform(assertSelected(true))
        Espresso.onView(
            Matchers.allOf(
                ViewMatchers.withText("OK"),
                ViewMatchers.withEffectiveVisibility(ViewMatchers.Visibility.VISIBLE)
            )
        ).check(ViewAssertions.matches(ViewMatchers.isDisplayed()))
        takeNamedScreenshot("activity_showcard_expanded")
    }
}
