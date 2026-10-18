package com.androidwebcam.app.util

import android.util.Log

/** Shared logging policy for Android camera and transport components. */
internal object AppLog {
    private const val TAG = "AWC"

    fun debug(component: String, message: String) {
        Log.d(TAG, "[$component] $message")
    }

    fun info(component: String, message: String) {
        Log.i(TAG, "[$component] $message")
    }

    fun warning(component: String, message: String, error: Throwable? = null) {
        if (error == null) Log.w(TAG, "[$component] $message")
        else Log.w(TAG, "[$component] $message", error)
    }

    fun error(component: String, message: String, error: Throwable? = null) {
        if (error == null) Log.e(TAG, "[$component] $message")
        else Log.e(TAG, "[$component] $message", error)
    }
}
