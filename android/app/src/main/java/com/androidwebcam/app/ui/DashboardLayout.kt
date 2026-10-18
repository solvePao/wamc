package com.androidwebcam.app.ui

import android.content.Context
import android.content.res.Configuration
import android.util.AttributeSet
import android.view.View
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.view.ViewGroup
import com.androidwebcam.app.R
import kotlin.math.min

/** Reserves room for the stream action and controls before sizing the square preview. */
class DashboardLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : ViewGroup(context, attrs) {
    private val gap get() = resources.getDimensionPixelSize(R.dimen.dashboard_spacing)
    private val landscape get() = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
    private lateinit var preview: View
    private lateinit var controls: View
    private lateinit var action: View
    private lateinit var cameraActions: View
    private lateinit var controlContent: LinearLayout
    private var compactActions = false

    override fun onFinishInflate() {
        super.onFinishInflate()
        preview = findViewById(R.id.previewContainer)
        controls = findViewById(R.id.controlsContainer)
        action = findViewById(R.id.toggle)
        cameraActions = findViewById(R.id.cameraActions)
        controlContent = findViewById(R.id.controlContent)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)
        val exact = MeasureSpec.EXACTLY
        val unspecified = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        val previewSize: Int
        val panelWidth: Int
        if (landscape) {
            previewSize = min(height, ((width - gap) * 0.44f).toInt()).coerceAtLeast(0)
            panelWidth = (width - previewSize - gap).coerceAtLeast(0)
        } else {
            panelWidth = width
            previewSize = 0 // Portrait preview is sized after measuring the controls.
        }
        action.measure(MeasureSpec.makeMeasureSpec(panelWidth, exact), unspecified)
        controls.measure(MeasureSpec.makeMeasureSpec(panelWidth, exact), unspecified)
        val available = (height - action.measuredHeight - gap).coerceAtLeast(0)
        fun previewSquare(): Int {
            if (landscape) return previewSize
            val minimum = min(width, (224 * resources.displayMetrics.density).toInt())
            val desired = available - controls.measuredHeight - gap
            // Leave at least one touch target visible in the scroll fallback.
            return min(width, desired.coerceAtLeast(minimum))
                .coerceAtMost((available - gap - (48 * resources.displayMetrics.density).toInt()).coerceAtLeast(0))
        }
        var square = previewSquare()
        val compact = square < 280 * resources.displayMetrics.density * resources.configuration.fontScale
        if (compactActions != compact) {
            compactActions = compact
            (cameraActions.parent as ViewGroup).removeView(cameraActions)
            if (compact) {
                controlContent.addView(cameraActions, 0,
                    LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                        bottomMargin = gap
                    })
            } else {
                (preview as FrameLayout).addView(cameraActions,
                    FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM).apply {
                        val margin = (10 * resources.displayMetrics.density).toInt()
                        setMargins(margin, margin, margin, margin)
                    })
            }
            controls.measure(MeasureSpec.makeMeasureSpec(panelWidth, exact), unspecified)
            square = previewSquare()
        }
        preview.findViewById<View>(R.id.previewEmptyTitle).visibility = if (compact) GONE else VISIBLE
        preview.findViewById<View>(R.id.previewEmptyHint).visibility = if (compact) GONE else VISIBLE
        val status = preview.findViewById<TextView>(R.id.status)
        val maxStatusLines = if (compact) 2 else 3
        if (status.maxLines != maxStatusLines) status.maxLines = maxStatusLines
        preview.measure(MeasureSpec.makeMeasureSpec(square, exact), MeasureSpec.makeMeasureSpec(square, exact))
        val controlsHeight = if (landscape) available else (available - square - gap).coerceAtLeast(0)
        controls.measure(MeasureSpec.makeMeasureSpec(panelWidth, exact), MeasureSpec.makeMeasureSpec(controlsHeight, exact))
        setMeasuredDimension(width, height)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val width = r - l
        val height = b - t
        val square = preview.measuredWidth
        val actionHeight = action.measuredHeight
        if (landscape) {
            val rtl = layoutDirection == LAYOUT_DIRECTION_RTL
            val previewLeft = if (rtl) width - square else 0
            val panelLeft = if (rtl) 0 else square + gap
            val panelRight = if (rtl) width - square - gap else width
            val previewTop = (height - square) / 2
            preview.layout(previewLeft, previewTop, previewLeft + square, previewTop + square)
            controls.layout(panelLeft, 0, panelRight, controls.measuredHeight)
            action.layout(panelLeft, height - actionHeight, panelRight, height)
        } else {
            val left = (width - square) / 2
            preview.layout(left, 0, left + square, square)
            controls.layout(0, square + gap, width, square + gap + controls.measuredHeight)
            action.layout(0, height - actionHeight, width, height)
        }
    }

    override fun generateDefaultLayoutParams() = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
    override fun generateLayoutParams(attrs: AttributeSet) = LayoutParams(context, attrs)
}
