package com.androidwebcam.app.ui

import android.content.Context
import android.util.AttributeSet
import android.view.TextureView

/** TextureView that always measures itself as a square (1:1). */
class SquareTextureView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : TextureView(context, attrs) {

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // Square = the smaller of the offered width and height, so the
        // preview stays 1:1 in both portrait and landscape.
        val widthMode = MeasureSpec.getMode(widthMeasureSpec)
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val heightMode = MeasureSpec.getMode(heightMeasureSpec)
        val height = MeasureSpec.getSize(heightMeasureSpec)

        val size = when {
            widthMode == MeasureSpec.UNSPECIFIED && heightMode == MeasureSpec.UNSPECIFIED -> 0
            widthMode == MeasureSpec.UNSPECIFIED -> height
            heightMode == MeasureSpec.UNSPECIFIED -> width
            else -> minOf(width, height)
        }
        setMeasuredDimension(size, size)
    }
}
