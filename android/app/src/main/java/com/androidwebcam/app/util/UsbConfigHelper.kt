package com.androidwebcam.app.util

import android.content.Context
import android.content.Intent
import android.provider.Settings
import java.io.DataOutputStream

object UsbConfigHelper {

    private const val PREFS_NAME = "wamc_usb_prefs"
    private const val KEY_SETUP_DISMISSED = "usb_setup_dismissed"

    fun isSetupDismissed(context: Context): Boolean {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_SETUP_DISMISSED, false)
    }

    fun setSetupDismissed(context: Context, dismissed: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_SETUP_DISMISSED, dismissed)
            .apply()
    }

    /**
     * Checks if Developer Options is enabled in Android settings.
     */
    fun isDeveloperOptionsEnabled(context: Context): Boolean {
        return try {
            Settings.Global.getInt(
                context.contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0
            ) == 1
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Attempts to execute the privileged USB mode switch via root (su)
     * setting both the persistent screen-unlocked default functions and active functions.
     */
    fun tryConfigureViaRoot(): Boolean = tryConfigureViaRoot { Runtime.getRuntime().exec("su") }

    internal fun tryConfigureViaRoot(startProcess: () -> Process): Boolean {
        return try {
            val process = startProcess()
            DataOutputStream(process.outputStream).use { os ->
                os.writeBytes("svc usb setScreenUnlockedFunctions mtp\n")
                os.writeBytes("svc usb setFunctions mtp\n")
                os.writeBytes("exit\n")
                os.flush()
            }
            process.waitFor() == 0
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Creates an Intent to open Developer Options directly (where "Default USB configuration" resides).
     */
    fun createDeveloperOptionsIntent(): Intent {
        return Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
    }

    /**
     * Creates an Intent to open About Phone if Developer Options is not enabled yet.
     */
    fun createAboutPhoneIntent(): Intent {
        return Intent(Settings.ACTION_DEVICE_INFO_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
    }
}

