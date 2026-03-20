// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo

/**
 * A11yInspector — runtime accessibility inspector for the visualizer app.
 *
 * Unlike A11yNavigator (which requires UiAutomation from instrumented tests),
 * this works from the app's own process by traversing the View hierarchy
 * and reading each view's AccessibilityNodeInfo. It provides the same
 * element discovery, focus, and interaction capabilities at runtime.
 *
 * Usage from RenderedCardFragment or any Activity:
 *
 *   val inspector = A11yInspector(cardContainerView)
 *   val elements = inspector.listElements()        // all a11y elements
 *   inspector.findByLabel("Reject")?.tap()         // tap by label
 *   inspector.printTree()                          // log full tree
 *   inspector.drawOverlays(canvas)                 // draw green rectangles
 */
class A11yInspector(private val rootView: View) {

    companion object {
        private const val TAG = "A11yInspector"
    }

    data class A11yElement(
        val index: Int,
        val label: String,
        val className: String,
        val bounds: Rect,
        val stateDescription: String,
        val isClickable: Boolean,
        val isFocusable: Boolean,
        val isChecked: Boolean,
        val isSelected: Boolean,
        val depth: Int,
        private val view: View
    ) {
        /** Tap this element by performing a click on the underlying view. */
        fun tap(): Boolean {
            return view.performClick()
        }

        /** Request accessibility focus on this element. */
        fun focus(): Boolean {
            val nodeInfo = view.createAccessibilityNodeInfo() ?: return false
            val result = view.performAccessibilityAction(
                AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null
            )
            nodeInfo.recycle()
            return result
        }

        /** Long press this element. */
        fun longPress(): Boolean {
            return view.performLongClick()
        }

        override fun toString(): String {
            val state = if (stateDescription.isNotEmpty()) " [$stateDescription]" else ""
            val click = if (isClickable) " (clickable)" else ""
            val indent = "  ".repeat(depth)
            return "$indent#$index $label$state$click [$className] (${bounds.left},${bounds.top})-(${bounds.right},${bounds.bottom})"
        }
    }

    /**
     * List all accessibility-visible elements in reading order.
     */
    fun listElements(): List<A11yElement> {
        val elements = mutableListOf<A11yElement>()
        collectFromView(rootView, elements, 0)
        return elements
    }

    /**
     * Find an element by its accessibility label (contentDescription or text).
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
     * Tap an element by its label. Returns true if found and tapped.
     */
    fun tapByLabel(label: String): Boolean {
        val element = findByLabel(label) ?: return false
        Log.i(TAG, "tap: $label -> ${element.bounds}")
        return element.tap()
    }

    /**
     * Walk accessibility focus through all elements sequentially.
     * Each element briefly gets accessibility focus.
     */
    fun walkFocus(delayMs: Long = 100) {
        val elements = listElements()
        for ((i, element) in elements.withIndex()) {
            element.focus()
            Log.i(TAG, "focus: #${i+1} ${element.label}")
            try { Thread.sleep(delayMs) } catch (_: InterruptedException) {}
        }
    }

    /**
     * Print the full accessibility tree to logcat.
     */
    fun printTree() {
        val elements = listElements()
        Log.i(TAG, "=== Accessibility Tree (${elements.size} elements) ===")
        for (el in elements) {
            Log.i(TAG, el.toString())
        }
    }

    /**
     * Draw numbered green overlay rectangles on a Canvas.
     * Call this from a custom View's onDraw() or an overlay view.
     */
    fun drawOverlays(canvas: Canvas) {
        val elements = listElements()
        val fillPaint = Paint().apply {
            color = Color.argb(60, 0, 200, 0)
            style = Paint.Style.FILL
        }
        val borderPaint = Paint().apply {
            color = Color.argb(255, 0, 220, 0)
            style = Paint.Style.STROKE
            strokeWidth = 3f
        }
        val textPaint = Paint().apply {
            color = Color.WHITE
            textSize = 28f
            isFakeBoldText = true
        }
        val badgePaint = Paint().apply {
            color = Color.argb(200, 0, 150, 0)
            style = Paint.Style.FILL
        }

        // Convert screen coordinates to view-local coordinates
        val rootLocation = IntArray(2)
        rootView.getLocationOnScreen(rootLocation)

        for ((i, el) in elements.withIndex()) {
            val r = Rect(
                el.bounds.left - rootLocation[0],
                el.bounds.top - rootLocation[1],
                el.bounds.right - rootLocation[0],
                el.bounds.bottom - rootLocation[1]
            )

            // Semi-transparent fill
            canvas.drawRect(r.left.toFloat(), r.top.toFloat(),
                r.right.toFloat(), r.bottom.toFloat(), fillPaint)

            // Green border
            canvas.drawRect(r.left.toFloat(), r.top.toFloat(),
                r.right.toFloat(), r.bottom.toFloat(), borderPaint)

            // Number badge
            val num = (i + 1).toString()
            val badgeSize = 32f
            canvas.drawCircle(
                r.left + badgeSize / 2, r.top - badgeSize / 2,
                badgeSize / 2, badgePaint
            )
            canvas.drawText(num,
                r.left + badgeSize / 2 - textPaint.measureText(num) / 2,
                r.top - badgeSize / 2 + textPaint.textSize / 3,
                textPaint
            )
        }
    }

    /**
     * Get a JSON-serializable summary of all elements.
     */
    fun toJson(): String {
        val elements = listElements()
        val sb = StringBuilder()
        sb.append("[\n")
        for ((i, el) in elements.withIndex()) {
            if (i > 0) sb.append(",\n")
            sb.append("  {")
            sb.append("\"index\":${el.index},")
            sb.append("\"label\":\"${el.label.replace("\"", "\\\"")}\",")
            sb.append("\"class\":\"${el.className}\",")
            sb.append("\"bounds\":[${el.bounds.left},${el.bounds.top},${el.bounds.right},${el.bounds.bottom}],")
            sb.append("\"clickable\":${el.isClickable},")
            sb.append("\"state\":\"${el.stateDescription}\"")
            sb.append("}")
        }
        sb.append("\n]")
        return sb.toString()
    }

    // ── Internal ──

    private var elementIndex = 0

    private fun collectFromView(view: View, out: MutableList<A11yElement>, depth: Int) {
        if (view.visibility != View.VISIBLE) return

        val nodeInfo = view.createAccessibilityNodeInfo()
        if (nodeInfo != null) {
            val desc = nodeInfo.contentDescription?.toString() ?: ""
            val text = nodeInfo.text?.toString() ?: ""
            val label = if (desc.isNotEmpty()) desc else text
            val className = view.javaClass.simpleName

            val stateDesc = if (Build.VERSION.SDK_INT >= 30) {
                nodeInfo.stateDescription?.toString() ?: ""
            } else ""

            val bounds = Rect()
            nodeInfo.getBoundsInScreen(bounds)

            if (label.isNotEmpty() && bounds.width() > 5 && bounds.height() > 5) {
                elementIndex++
                out.add(A11yElement(
                    index = elementIndex,
                    label = label,
                    className = className,
                    bounds = bounds,
                    stateDescription = stateDesc,
                    isClickable = nodeInfo.isClickable,
                    isFocusable = nodeInfo.isFocusable,
                    isChecked = nodeInfo.isChecked,
                    isSelected = nodeInfo.isSelected,
                    depth = depth,
                    view = view
                ))
            }
            nodeInfo.recycle()
        }

        // Recurse into children
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                collectFromView(view.getChildAt(i), out, depth + 1)
            }
        }
    }
}
