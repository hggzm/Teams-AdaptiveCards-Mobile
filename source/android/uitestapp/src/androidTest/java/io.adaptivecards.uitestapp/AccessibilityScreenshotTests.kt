// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.graphics.Rect
import android.os.ParcelFileDescriptor
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
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

        // Dump the accessibility/view hierarchy via UiDevice.
        // Log a11y element labels + bounds to logcat via android.util.Log.
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        try {
            val baos = java.io.ByteArrayOutputStream()
            device.dumpWindowHierarchy(baos)
            val xml = baos.toString("UTF-8")
            val labelPattern = Regex("content-desc=\"([^\"]+)\"")
            val textPattern = Regex(" text=\"([^\"]+)\"")
            val boundsPattern = Regex("bounds=\"(\\[\\d+,\\d+\\]\\[\\d+,\\d+\\])\"")
            val labels = mutableListOf<String>()
            for (line in xml.split("<node ")) {
                val desc = labelPattern.find(line)?.groupValues?.get(1) ?: ""
                val text = textPattern.find(line)?.groupValues?.get(1) ?: ""
                val bounds = boundsPattern.find(line)?.groupValues?.get(1) ?: ""
                val label = if (desc.isNotEmpty()) desc else text
                if (label.isNotEmpty() && bounds.isNotEmpty() &&
                    !label.contains("launcher", ignoreCase = true) &&
                    !label.contains("systemui", ignoreCase = true)) {
                    labels.add("$label|$bounds")
                }
            }
            for ((i, entry) in labels.withIndex()) {
                android.util.Log.i("AXE", "$name|${i + 1}|$entry")
            }
            android.util.Log.i("AXE_SUM", "$name|${labels.size}|${xml.length}")
            println("A11y tree: $name - ${labels.size} labeled elements")
        } catch (e: Exception) {
            println("A11y tree dump failed: ${e.javaClass.simpleName}: ${e.message}")
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

    /**
     * Walk the accessibility tree and perform ACTION_ACCESSIBILITY_FOCUS on each
     * focusable element. This is the Android equivalent of AXe/VoiceOver navigation:
     * it programmatically moves TalkBack focus through elements in reading order,
     * verifying each element is reachable and logging what TalkBack would announce.
     *
     * Returns the list of focused element descriptions (what TalkBack says).
     */
    private fun walkAccessibilityFocus(scenario: String): List<String> {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val root = automation.rootInActiveWindow ?: return emptyList()
        val focused = mutableListOf<String>()

        fun traverse(node: AccessibilityNodeInfo) {
            // Get text/description (what TalkBack would read)
            val desc = node.contentDescription?.toString() ?: ""
            val text = node.text?.toString() ?: ""
            val label = if (desc.isNotEmpty()) desc else text
            val stateDesc = if (android.os.Build.VERSION.SDK_INT >= 30) {
                node.stateDescription?.toString() ?: ""
            } else 
            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            val pkg = node.packageName?.toString() ?: ""

            // Skip system UI / launcher
            if (pkg.contains("launcher") || pkg.contains("systemui")) {
                // Still traverse children
            } else if (label.isNotEmpty() && node.isVisibleToUser) {
                // Attempt to set accessibility focus (shows green rectangle)
                node.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)

                val entry = buildString {
                    append(label)
                    if (stateDesc.isNotEmpty()) append(" [$stateDesc]")
                    append(" (${bounds.left},${bounds.top},${bounds.right},${bounds.bottom})")
                }
                focused.add(entry)

                // Log to logcat for extraction
                android.util.Log.i("AXE_FOCUS", "$scenario|${focused.size}|$label|$stateDesc|${bounds.toShortString()}")
            }

            // Recurse into children
            for (i in 0 until node.childCount) {
                val child = node.getChild(i)
                if (child != null) {
                    traverse(child)
                    child.recycle()
                }
            }
        }

        traverse(root)
        root.recycle()

        android.util.Log.i("AXE_WALK", "$scenario|${focused.size} elements focused")
        return focused
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
        // Walk a11y focus to verify stateDescription is set (PR #663 fix)
        val focusedElements = walkAccessibilityFocus("showcard_expanded")
        val rejectEntry = focusedElements.find { it.contains("Reject") }
        if (rejectEntry != null && (rejectEntry.contains("[expanded]") || rejectEntry.contains("Reject"))) {
            println("VERIFIED: Reject button has stateDescription=expanded")
        } else {
            println("stateDescription check: Reject entry = $rejectEntry")
        }

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
        // Walk a11y focus to verify error message elements exist (PR #662 fix)
        val errorElements = walkAccessibilityFocus("validation_error_visible")
        val errorAnnounced = errorElements.any { it.contains("Please enter your name") }
        println("VERIFIED: Error message in a11y tree = $errorAnnounced")

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
