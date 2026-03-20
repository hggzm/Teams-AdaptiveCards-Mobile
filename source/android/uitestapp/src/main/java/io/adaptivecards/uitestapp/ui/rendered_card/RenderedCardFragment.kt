// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
package io.adaptivecards.uitestapp.ui.rendered_card

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import io.adaptivecards.objectmodel.*
import io.adaptivecards.renderer.AdaptiveCardRenderer
import io.adaptivecards.renderer.RenderedAdaptiveCard
import io.adaptivecards.renderer.actionhandler.ICardActionHandler
import io.adaptivecards.uitestapp.A11yInspector
import io.adaptivecards.uitestapp.A11yOverlayView
import io.adaptivecards.uitestapp.R
import android.widget.FrameLayout
import io.adaptivecards.uitestapp.ui.inputs.RetrievedInput
import io.adaptivecards.uitestapp.ui.test_cases.TestCasesViewModel
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.util.*

class RenderedCardFragment : Fragment(), ICardActionHandler {
    private var mRenderedCardViewModel: RenderedCardViewModel? = null
    private var mTestCasesViewModel: TestCasesViewModel? = null
    private var mCardContainer: LinearLayout? = null
    private var mA11yOverlay: A11yOverlayView? = null
    private var mA11yInspector: A11yInspector? = null
    override fun onCreateView(inflater: LayoutInflater,
                              container: ViewGroup?, savedInstanceState: Bundle?): View? {
        mRenderedCardViewModel = ViewModelProvider(requireActivity()).get(RenderedCardViewModel::class.java)
        mTestCasesViewModel = ViewModelProvider(requireActivity()).get(TestCasesViewModel::class.java)
        val root = inflater.inflate(R.layout.fragment_rendered_card, container, false)
        mCardContainer = root.findViewById(R.id.layout_cardContainer)
        // Add a11y overlay (toggle via adb: adb shell am broadcast -a io.adaptivecards.A11Y_TOGGLE)
        mA11yOverlay = A11yOverlayView(requireContext())
        mA11yOverlay!!.visibility = View.GONE
        (root as? ViewGroup)?.addView(mA11yOverlay, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        mTestCasesViewModel!!.lastClickedItem.observe(viewLifecycleOwner,
                TestCaseObserver(this))
        return root
    }

    override fun onAction(actionElement: BaseActionElement, renderedAdaptiveCard: RenderedAdaptiveCard) {
        val actionType = actionElement.GetElementType()
        if (actionType == ActionType.Submit) {
            val keyValueMap = renderedAdaptiveCard.inputs
            val retrievedInputList: MutableList<RetrievedInput> = ArrayList()
            for ((key, value) in keyValueMap) {
                retrievedInputList.add(RetrievedInput(key!!, value!!))
            }
            mRenderedCardViewModel!!.inputs.value = retrievedInputList
        }
    }

    override fun onMediaPlay(mediaElement: BaseCardElement, renderedAdaptiveCard: RenderedAdaptiveCard) {}
    override fun onMediaStop(mediaElement: BaseCardElement, renderedAdaptiveCard: RenderedAdaptiveCard) {}
    private inner class TestCaseObserver(var m_cardActionHandler: ICardActionHandler) : Observer<String> {
        override fun onChanged(testCase: String) {
            activity!!.title = testCase
            val adaptiveCardContents = readAdaptiveCardJson(testCase)
            renderCard(adaptiveCardContents)
        }

        private fun renderCard(adaptiveCardContents: String?) {
            try {
                val parseResult = AdaptiveCard.DeserializeFromString(adaptiveCardContents,
                        AdaptiveCardRenderer.VERSION)
                mCardContainer!!.removeAllViews()
                val renderedCard = AdaptiveCardRenderer.getInstance().render(context,
                        activity!!.supportFragmentManager,
                        parseResult.GetAdaptiveCard(),
                        m_cardActionHandler,
                        HostConfig())
                mCardContainer!!.addView(renderedCard.view)

                // Attach a11y inspector to the rendered card
                mCardContainer!!.post {
                    mA11yInspector = A11yInspector(mCardContainer!!)
                    mA11yOverlay?.attachTo(mCardContainer!!)
                    mA11yInspector?.printTree()
                }
            } catch (ex: Exception) {
            }
        }

        private fun readAdaptiveCardJson(testCase: String): String? {
            try {
                val cardContents = requireActivity().assets.open(testCase).bufferedReader().use {
                    it.readText()
                }
                return cardContents
            } catch (ioExcep: IOException) {
            }
            return null
        }
    }

    /**
     * Toggle the accessibility overlay on the rendered card.
     * Shows numbered green rectangles over each TalkBack-visible element.
     *
     * Call from test:   fragment.toggleA11yOverlay()
     * Call from adb:    adb shell am broadcast -a io.adaptivecards.A11Y_TOGGLE
     * Call from code:   (activity as? RenderCardUiTestAppActivity)?.let {
     *                       val frag = it.supportFragmentManager.fragments
     *                           .filterIsInstance<RenderedCardFragment>().first()
     *                       frag.toggleA11yOverlay()
     *                   }
     */
    fun toggleA11yOverlay() {
        mA11yOverlay?.let { overlay ->
            if (overlay.visibility == View.GONE) {
                overlay.visibility = View.VISIBLE
                overlay.refresh()
                android.util.Log.i("A11yInspector", "Overlay ENABLED")
                // Also print tree when enabling
                mA11yInspector?.printTree()
            } else {
                overlay.visibility = View.GONE
                android.util.Log.i("A11yInspector", "Overlay DISABLED")
            }
        }
    }

    /** Get the inspector instance for programmatic a11y queries. */
    fun getA11yInspector(): A11yInspector? = mA11yInspector
}
