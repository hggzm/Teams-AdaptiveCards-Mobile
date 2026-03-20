// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.graphics.Rect
import android.os.ParcelFileDescriptor
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * A11yNavigator — Android equivalent of iOS AXe framework.
 *
 * Provides programmatic accessibility-driven UI automation using the
 * same AccessibilityNodeInfo tree that TalkBack navigates. All element
 * discovery and interaction is done via accessibility identifiers
 * (contentDescription, text, stateDescription) — no view IDs or
 * coordinates needed.
 *
 * Usage:
 *   val nav = A11yNavigator()
 *   nav.findByLabel("Reject")?.tap()
 *   nav.findByLabel("Submit")?.tap()
 *   val elements = nav.listElements()  // all TalkBack-visible elements
 *   nav.walkFocus("scenario_name")     // walk focus with screenshots
 */
class A11yNavigator {

    data class A11yElement(
        val label: String,
        val className: String,
        val bounds: Rect,
        val stateDescription: String,
        val isClickable: Boolean,
        val isFocusable: Boolean,
        val isChecked: Boolean,
        val isSelected: Boolean,
        val nodeInfo: AccessibilityNodeInfo
    ) {
        /** Tap this element via accessibility action. */
        fun tap(): Boolean {
            return nodeInfo.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }

        /** Set accessibility focus (shows TalkBack green rectangle). */
        fun focus(): Boolean {
            return nodeInfo.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
        }

        /** Scroll forward within this element. */
        fun scrollForward(): Boolean {
            return nodeInfo.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
        }

        /** Long press this element. */
        fun longPress(): Boolean {
            return nodeInfo.performAction(AccessibilityNodeInfo.ACTION_LONG_CLICK)
        }

        override fun toString(): String {
            val state = if (stateDescription.isNotEmpty()) " [$stateDescription]" else ""
            val click = if (isClickable) " (clickable)" else ""
            return "$label$state$click [${bounds.left},${bounds.top},${bounds.right},${bounds.bottom}]"
        }
    }

    private val automation = InstrumentationRegistry.getInstrumentation().uiAutomation

    /**
     * Get the root AccessibilityNodeInfo of the active window.
     * This is the same tree TalkBack uses.
     */
    private fun getRoot(): AccessibilityNodeInfo? = automation.rootInActiveWindow

    /**
     * List all accessibility-visible elements in reading order.
     * Filters out system UI (status bar, navigation bar, launcher).
     */
    fun listElements(): List<A11yElement> {
        val root = getRoot() ?: return emptyList()
        val elements = mutableListOf<A11yElement>()
        collectElements(root, elements)
        root.recycle()
        return elements
    }

    /**
     * Find an element by its accessibility label (contentDescription or text).
     * Returns the first match, or null if not found.
     */
    fun findByLabel(label: String): A11yElement? {
        return listElements().find {
            it.label.equals(label, ignoreCase = true) ||
            it.label.contains(label, ignoreCase = true)
        }
    }

    /**
     * Find all elements matching a label pattern.
     */
    fun findAllByLabel(pattern: String): List<A11yElement> {
        return listElements().filter {
            it.label.contains(pattern, ignoreCase = true)
        }
    }

    /**
     * Find an element by its class name suffix (e.g., "Button", "EditText").
     */
    fun findByClass(classNameSuffix: String): List<A11yElement> {
        return listElements().filter {
            it.className.endsWith(classNameSuffix, ignoreCase = true)
        }
    }

    /**
     * Find an element by stateDescription (e.g., "expanded", "collapsed").
     * Requires API 30+.
     */
    fun findByState(state: String): List<A11yElement> {
        return listElements().filter {
            it.stateDescription.equals(state, ignoreCase = true)
        }
    }

    /**
     * Tap an element by its label. Returns true if found and tapped.
     */
    fun tapByLabel(label: String): Boolean {
        val element = findByLabel(label) ?: return false
        android.util.Log.i("A11Y_NAV", "tap: $label -> ${element.bounds}")
        return element.tap()
    }

    /**
     * Walk TalkBack focus through all elements, pausing briefly on each.
     * This makes the green focus rectangle visible in screen recordings.
     * Returns the list of focused elements (what TalkBack would announce).
     */
    fun walkFocus(scenario: String, delayMs: Long = 80): List<A11yElement> {
        val elements = listElements()
        for ((i, element) in elements.withIndex()) {
            element.focus()
            Thread.sleep(delayMs)
            android.util.Log.i("A11Y_NAV", "focus[$scenario]: #${i+1} ${element.label}")
        }
        android.util.Log.i("A11Y_NAV", "walk[$scenario]: ${elements.size} elements")
        return elements
    }

    /**
     * Take a screenshot to /data/local/tmp/ and return the path.
     */
    fun screenshot(name: String): String {
        val dir = "/data/local/tmp/a11y_screenshots"
        val path = "$dir/android_a11y_$name.png"
        execShell("mkdir -p $dir")
        execShell("screencap -p $path")
        return path
    }

    /**
     * Dump a11y element info to logcat for CI extraction.
     */
    fun logElements(scenario: String) {
        val elements = listElements()
        for ((i, el) in elements.withIndex()) {
            android.util.Log.i("AXE", "$scenario|${i+1}|${el.label}|${el.bounds.toShortString()}")
        }
        android.util.Log.i("AXE_SUM", "$scenario|${elements.size}")
    }

    private fun execShell(cmd: String): String {
        val pfd = automation.executeShellCommand(cmd)
        return BufferedReader(
            InputStreamReader(ParcelFileDescriptor.AutoCloseInputStream(pfd))
        ).use { it.readText().trim() }
    }

    private fun collectElements(node: AccessibilityNodeInfo, out: MutableList<A11yElement>) {
        val desc = node.contentDescription?.toString() ?: ""
        val text = node.text?.toString() ?: ""
        val label = if (desc.isNotEmpty()) desc else text
        val pkg = node.packageName?.toString() ?: ""
        val cls = node.className?.toString()?.substringAfterLast('.') ?: ""
        val bounds = Rect()
        node.getBoundsInScreen(bounds)

        val stateDesc = if (android.os.Build.VERSION.SDK_INT >= 30) {
            node.stateDescription?.toString() ?: ""
        } else ""

        // Skip system UI
        if (pkg.contains("launcher") || pkg.contains("systemui") ||
            pkg.contains("nexuslauncher")) {
            // still traverse children in case app is behind
        } else if (label.isNotEmpty() && node.isVisibleToUser && bounds.width() > 5 && bounds.height() > 5) {
            out.add(A11yElement(
                label = label,
                className = cls,
                bounds = bounds,
                stateDescription = stateDesc,
                isClickable = node.isClickable,
                isFocusable = node.isFocusable,
                isChecked = node.isChecked,
                isSelected = node.isSelected,
                nodeInfo = node
            ))
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            if (child != null) {
                collectElements(child, out)
                // Don't recycle children — they're referenced by A11yElement
            }
        }
    }
}
