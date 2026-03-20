// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.os.ParcelFileDescriptor
import androidx.test.espresso.Espresso
import androidx.test.espresso.action.ViewActions
import androidx.test.espresso.matcher.ViewMatchers
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.hamcrest.Matchers
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.Timeout
import org.junit.runner.RunWith
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Accessibility-driven UI automation tests.
 *
 * These tests navigate and interact with Adaptive Cards using ONLY
 * accessibility identifiers (contentDescription, text, stateDescription)
 * via the A11yNavigator helper — no view IDs or screen coordinates.
 *
 * This demonstrates that the cards are fully navigable and operable
 * through assistive technology (TalkBack), proving that a screen reader
 * user can complete the same workflows as a sighted user.
 *
 * Similar to iOS AXe which uses Apple's private accessibility APIs:
 *   axe tap --label "Reject" --udid SIMULATOR
 *   axe describe-ui --udid SIMULATOR
 *
 * Android equivalent:
 *   nav.tapByLabel("Reject")
 *   nav.listElements()
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class A11yNavigatorTests {

    companion object {
        init {
            System.loadLibrary("adaptivecards-native-lib")
        }
    }

    private val nav = A11yNavigator()

    @get:Rule
    val testRule: RuleChain = RuleChain
        .outerRule(GrantPermissionRule.grant(android.Manifest.permission.WRITE_EXTERNAL_STORAGE))
        .around(ActivityScenarioRule<RenderCardUiTestAppActivity>(
            RenderCardUiTestAppActivity::class.java))
        .around(Timeout.seconds(120))

    private fun renderCard(cardName: String) {
        Espresso.onData(Matchers.`is`(cardName)).perform(ViewActions.click())
        TestHelpers.goToRenderedCardScreen()
        Thread.sleep(3000)
    }

    private fun screencap(name: String) {
        Thread.sleep(300)
        nav.walkFocus(name, delayMs = 60)
        Thread.sleep(200)
        nav.screenshot(name)
        nav.logElements(name)
    }

    // ---------------------------------------------------------------
    // Test 1: Navigate ExpenseReport purely via a11y labels
    // Demonstrates: find elements, verify labels, tap ShowCard
    // ---------------------------------------------------------------

    @Test
    fun nav_expense_report_showcard_workflow() {
        renderCard("ExpenseReport.json")

        // 1. Verify key elements are discoverable by label
        val elements = nav.listElements()
        assertTrue("Should find accessibility elements", elements.size > 10)

        val approveBtn = nav.findByLabel("Approve")
        assertNotNull("Approve button should be findable by label", approveBtn)

        val rejectBtn = nav.findByLabel("Reject")
        assertNotNull("Reject button should be findable by label", rejectBtn)

        screencap("nav_expense_before")

        // 2. Tap Reject via accessibility label (not coordinates)
        val tapped = nav.tapByLabel("Reject")
        assertTrue("Should be able to tap Reject by label", tapped)
        Thread.sleep(1500)

        // 3. Verify ShowCard expanded — new elements should appear
        val afterElements = nav.listElements()
        val rejectionInput = nav.findByLabel("appropriate reason for rejection")
        assertNotNull("Rejection reason input should appear after ShowCard expand", rejectionInput)

        screencap("nav_expense_after_reject")

        // 4. Tap Reject again to collapse
        nav.tapByLabel("Reject")
        Thread.sleep(1000)

        // 5. Verify ShowCard collapsed — rejection input gone
        val collapsedElements = nav.listElements()
        val rejectionGone = nav.findByLabel("appropriate reason for rejection")
        assertNull("Rejection input should be gone after collapse", rejectionGone)

        screencap("nav_expense_collapsed")
    }

    // ---------------------------------------------------------------
    // Test 2: Navigate InputForm and trigger validation via a11y
    // Demonstrates: find input fields, tap submit, verify error labels
    // ---------------------------------------------------------------

    @Test
    fun nav_input_form_validation_workflow() {
        renderCard("InputForm.json")

        // 1. Discover form elements by label
        val nameField = nav.findByLabel("Your name")
        assertNotNull("Name field should be findable", nameField)

        val submitBtn = nav.findByLabel("Submit")
        assertNotNull("Submit button should be findable", submitBtn)

        screencap("nav_form_empty")

        // 2. Tap Submit without filling fields (trigger validation)
        val submitted = nav.tapByLabel("Submit")
        assertTrue("Should tap Submit by label", submitted)
        Thread.sleep(1500)

        // 3. Verify error messages are now in the a11y tree
        val errorElements = nav.findAllByLabel("Please enter your name")
        assertTrue("Error message should appear in a11y tree after validation failure",
            errorElements.isNotEmpty())

        screencap("nav_form_errors")
    }

    // ---------------------------------------------------------------
    // Test 3: Navigate ActivityUpdate ShowCard via a11y
    // Demonstrates: tap ShowCard by label, verify expanded content
    // ---------------------------------------------------------------

    @Test
    fun nav_activity_update_comment_workflow() {
        renderCard("ActivityUpdate.json")

        // 1. Find action buttons
        val commentBtn = nav.findByLabel("Comment")
        assertNotNull("Comment button findable by label", commentBtn)

        val dueDateBtn = nav.findByLabel("Set due date")
        assertNotNull("Set due date button findable by label", dueDateBtn)

        screencap("nav_activity_buttons")

        // 2. Tap Comment via a11y label
        nav.tapByLabel("Comment")
        Thread.sleep(1500)

        // 3. Verify ShowCard expanded — OK button and input should appear
        val okBtn = nav.findByLabel("OK")
        assertNotNull("OK button should appear after Comment ShowCard expands", okBtn)

        screencap("nav_activity_comment_expanded")

        // 4. Tap Set due date (should collapse Comment, expand date)
        nav.tapByLabel("Set due date")
        Thread.sleep(1500)

        screencap("nav_activity_date_expanded")
    }

    // ---------------------------------------------------------------
    // Test 4: Full a11y element inventory
    // Demonstrates: list all elements, verify counts, log for CI
    // ---------------------------------------------------------------

    @Test
    fun nav_element_inventory() {
        renderCard("ExpenseReport.json")

        val elements = nav.listElements()
        assertTrue("ExpenseReport should have 20+ accessible elements", elements.size >= 20)

        // Verify specific element types are present
        val clickableCount = elements.count { it.isClickable }
        assertTrue("Should have clickable elements (buttons)", clickableCount > 0)

        // Log full inventory
        for ((i, el) in elements.withIndex()) {
            android.util.Log.i("A11Y_INV", "#${i+1}: $el")
        }

        screencap("nav_element_inventory")
    }
}
