// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp

import android.content.Context
import android.graphics.Canvas
import android.util.AttributeSet
import android.view.View

/**
 * A11yOverlayView — transparent overlay that draws numbered green rectangles
 * over each accessibility element, similar to RocketSim's VoiceOver Navigator.
 *
 * Add this view on top of the card container and call refresh() after the
 * card is rendered. Toggle visibility to show/hide the overlay.
 *
 * Usage in RenderedCardFragment:
 *   val overlay = A11yOverlayView(context)
 *   parentLayout.addView(overlay)
 *   overlay.attachTo(cardContainer)
 *   overlay.refresh()
 */
class A11yOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private var inspector: A11yInspector? = null

    /**
     * Attach to a root view to inspect its accessibility tree.
     */
    fun attachTo(rootView: View) {
        inspector = A11yInspector(rootView)
    }

    /**
     * Refresh the overlay (re-read the accessibility tree and redraw).
     */
    fun refresh() {
        inspector?.let {
            invalidate()
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        inspector?.drawOverlays(canvas)
    }
}
